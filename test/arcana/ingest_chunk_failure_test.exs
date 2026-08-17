defmodule Arcana.IngestChunkFailureTest do
  @moduledoc """
  What a single rejected chunk does to the rest of the ingest.

  Storing chunks as they embedded used to leave the document row and every
  chunk before the failure behind. Nothing filters retrieval by document
  status, so those chunks stayed searchable under a document marked
  `:failed` - a silently half-indexed document.
  """
  use Arcana.DataCase, async: true

  # One chunk in the middle is rejected the way an endpoint rejects
  # oversized input; the rest embed normally.
  defp poison_embedder do
    fn text ->
      if String.contains?(text, "POISON") do
        {:error, :rejected_by_endpoint}
      else
        {:ok, List.duplicate(0.1, 384)}
      end
    end
  end

  defp text_with_poison_at(section) do
    Enum.map_join(1..6, "\n\n", fn
      ^section -> "Section #{section}. " <> String.duplicate("POISON ", 120)
      i -> "Section #{i}. " <> String.duplicate("harmless filler about refunds. ", 60)
    end)
  end

  defp counts do
    {length(Repo.all(Arcana.Document)), length(Repo.all(Arcana.Chunk))}
  end

  describe "on_chunk_error: :abort (the default)" do
    test "leaves no document and no chunks behind" do
      put_arcana_env(:embedder, poison_embedder())

      assert {:error, {:embedding_failed, failure}} =
               Arcana.ingest(text_with_poison_at(4), repo: Repo, collection: "abort-clean")

      assert failure.reason == :rejected_by_endpoint

      assert is_integer(failure.chunk_index),
             "the error has to name the chunk so the caller can fix the input"

      assert counts() == {0, 0},
             "a failed ingest must not leave a document or its chunks behind"
    end

    test "leaves nothing searchable" do
      put_arcana_env(:embedder, poison_embedder())

      assert {:error, _} =
               Arcana.ingest(text_with_poison_at(4), repo: Repo, collection: "abort-search")

      assert {:ok, []} = Arcana.search("refunds", repo: Repo),
             "chunks from a failed ingest were searchable under a :failed document"
    end

    test "a fully embeddable document is unaffected" do
      put_arcana_env(:embedder, poison_embedder())

      clean = Enum.map_join(1..4, "\n\n", &"Section #{&1}. #{String.duplicate("fine. ", 80)}")

      assert {:ok, document} = Arcana.ingest(clean, repo: Repo, collection: "abort-happy")
      assert document.status == :completed
      assert document.chunk_count > 0
    end
  end

  describe "on_chunk_error: :skip" do
    test "stores the good chunks and reports the skipped one" do
      put_arcana_env(:embedder, poison_embedder())

      assert {:ok, document, report} =
               Arcana.ingest(text_with_poison_at(4),
                 repo: Repo,
                 collection: "skip-partial",
                 on_chunk_error: :skip
               )

      assert document.status == :completed
      assert report.skipped_chunks >= 1
      assert :rejected_by_endpoint in report.reasons

      assert document.chunk_count > 0
      assert document.chunk_count == length(Repo.all(Arcana.Chunk))

      # Why it was partial has to survive on the row, not only in the return.
      assert document.error =~ "skipped"

      refute Enum.any?(Repo.all(Arcana.Chunk), &String.contains?(&1.text, "POISON")),
             "the rejected chunk must not be stored"
    end

    test "the surviving chunks are searchable" do
      put_arcana_env(:embedder, poison_embedder())

      assert {:ok, _document, _report} =
               Arcana.ingest(text_with_poison_at(4),
                 repo: Repo,
                 collection: "skip-search",
                 on_chunk_error: :skip
               )

      assert {:ok, [_ | _]} = Arcana.search("refunds", repo: Repo),
             "39 of 40 chunks beats losing the document"
    end

    test "skipped chunks leave a gap rather than renumbering" do
      put_arcana_env(:embedder, poison_embedder())

      assert {:ok, _document, report} =
               Arcana.ingest(text_with_poison_at(4),
                 repo: Repo,
                 collection: "skip-gaps",
                 on_chunk_error: :skip
               )

      stored = Repo.all(Arcana.Chunk) |> Enum.map(& &1.chunk_index) |> Enum.sort()
      skipped = Enum.map(report.failed, & &1.chunk_index)

      assert stored == Enum.sort(stored) |> Enum.uniq()

      for index <- skipped do
        refute index in stored,
               "a skipped index must not be reused: byte offsets are the source of truth"
      end
    end

    test "every chunk failing is an error, not an empty document" do
      put_arcana_env(:embedder, fn _text -> {:error, :always_down} end)

      assert {:error, {:all_chunks_failed, failures}} =
               Arcana.ingest("some text to embed here. ",
                 repo: Repo,
                 collection: "skip-total",
                 on_chunk_error: :skip
               )

      assert failures != []

      assert counts() == {0, 0},
             "a zero-chunk document is invisible to search but present in listings"
    end
  end

  describe "replace: true" do
    test "a failed replacement leaves the previous document intact" do
      put_arcana_env(:embedder, poison_embedder())

      clean = Enum.map_join(1..4, "\n\n", &"Section #{&1}. #{String.duplicate("refunds. ", 80)}")

      assert {:ok, first} =
               Arcana.ingest(clean, repo: Repo, collection: "replace-safe", source_id: "doc-1")

      assert {:error, _} =
               Arcana.ingest(text_with_poison_at(4),
                 repo: Repo,
                 collection: "replace-safe",
                 source_id: "doc-1",
                 replace: true
               )

      assert [%{id: id}] = Repo.all(Arcana.Document)
      assert id == first.id, "the predecessor has to survive a failed replacement"

      assert {:ok, [_ | _]} = Arcana.search("refunds", repo: Repo)
    end
  end

  describe "a misbehaving embedder" do
    defmodule BareVectorEmbedder do
      @moduledoc false
      @behaviour Arcana.Embedder
      # Returns the vector itself instead of {:ok, vector}. Arcana.Embedder
      # hands a module's return back unchecked, so this reaches ingest.
      @impl true
      def embed(_text, _opts), do: List.duplicate(0.1, 384)
      @impl true
      def dimensions(_opts), do: 384
    end

    test "a module returning a bare vector is reported, not a FunctionClauseError" do
      put_arcana_env(:embedder, BareVectorEmbedder)

      assert {:error, {:embedding_failed, %{reason: {:unexpected_result, _}}}} =
               Arcana.ingest("some text to embed here. ", repo: Repo, collection: "bad-embedder")

      assert counts() == {0, 0}
    end
  end

  describe "option validation" do
    test "an unknown on_chunk_error is rejected" do
      assert_raise ArgumentError, ~r/on_chunk_error must be :abort or :skip/, fn ->
        Arcana.ingest("text", repo: Repo, on_chunk_error: :bogus)
      end
    end
  end
end
