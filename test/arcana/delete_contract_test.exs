defmodule Arcana.DeleteContractTest do
  @moduledoc """
  `Arcana.delete/2` returning what its docs promise.

  It used to call `repo.delete!/1`, so a foreign key violation or a
  concurrent delete escaped as an exception from a function documenting
  `:ok | {:error, :not_found} | {:error, term()}`. The damage was
  not the exception itself but the sequencing around it: callers remove an
  external artifact and then call this, and a three-clause `case` written
  from the docs gave them no reason to expect control to leave abruptly.

  The cases needing a host table with a foreign key onto `arcana_documents`
  live in `Arcana.DeleteContractDDLTest` instead, because creating that
  constraint takes a `ShareRowExclusiveLock` on `arcana_documents` for the
  whole test and would serialize every async test that writes documents.
  """
  use Arcana.DataCase, async: true

  alias Arcana.Graph.GraphStore

  defp ingest_doc(text \\ "Elixir runs on the BEAM.") do
    {:ok, doc} = Arcana.ingest(text, repo: Repo)
    doc
  end

  describe "the documented happy paths still hold" do
    test "deleting a document returns :ok and removes it" do
      doc = ingest_doc()

      assert :ok = Arcana.delete(doc.id, repo: Repo)
      refute Repo.get(Arcana.Document, doc.id)
    end

    test "an unknown id is :not_found" do
      assert {:error, :not_found} = Arcana.delete(Ecto.UUID.generate(), repo: Repo)
    end

    test "a document deleted out from under us reads as :not_found" do
      # This lands on the repo.get/2 branch, not the Ecto.StaleEntryError
      # rescue: the row is already gone by the time delete/2 looks for it.
      # Forcing the actual race - present at the lookup, gone at the delete -
      # needs an interleave inside delete/2 that the sandbox cannot arrange,
      # so the rescue itself is defensive and uncovered. It reports the same
      # :not_found either way, which is the contract being pinned here.
      doc = ingest_doc()

      Repo.delete_all(from(c in Arcana.Chunk, where: c.document_id == ^doc.id))
      Repo.delete_all(from(d in Arcana.Document, where: d.id == ^doc.id))

      assert {:error, :not_found} = Arcana.delete(doc.id, repo: Repo)
    end
  end

  describe "inside a caller's own transaction" do
    test "an external graph store refuses deletion it cannot clean after commit" do
      extractor = fn _t, _o -> {:ok, [%{name: "Alpha", type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        graph_store: Arcana.FailingSweepGraphStore,
        collection: "delete-contract-sweep"
      ]

      {:ok, doc} = Arcana.ingest("alpha", Keyword.put(opts, :entity_extractor, extractor))

      result =
        Repo.transaction(fn ->
          deleted = Arcana.delete(doc.id, opts)

          {deleted, Repo.get(Arcana.Document, doc.id)}
        end)

      assert {:ok, {{:error, :external_graph_store_requires_post_commit_delete}, persisted}} =
               result

      assert persisted.id == doc.id
    end
  end

  describe "the delete and the sweep are one unit" do
    test "chunks go with the document" do
      doc = ingest_doc("Elixir runs on the BEAM virtual machine, which is Erlang's.")

      chunks = fn ->
        Repo.aggregate(from(c in Arcana.Chunk, where: c.document_id == ^doc.id), :count)
      end

      assert chunks.() > 0

      assert :ok = Arcana.delete(doc.id, repo: Repo)

      assert chunks.() == 0
    end

    test "an external cleanup failure is reported after the database delete commits" do
      extractor = fn _t, _o -> {:ok, [%{name: "Beta", type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        graph_store: Arcana.FailingSweepGraphStore,
        collection: "delete-contract-chunks"
      ]

      {:ok, doc} =
        Arcana.ingest(
          "beta content that is long enough to chunk",
          Keyword.put(opts, :entity_extractor, extractor)
        )

      chunks = fn ->
        Repo.aggregate(from(c in Arcana.Chunk, where: c.document_id == ^doc.id), :count)
      end

      assert chunks.() > 0

      chunk_ids = Repo.all(from(c in Arcana.Chunk, where: c.document_id == ^doc.id, select: c.id))

      assert {:error,
              {:post_commit_graph_cleanup_failed,
               %{
                 reason: {:sweep_failed, :sweep_boom},
                 chunk_ids: ^chunk_ids,
                 published_chunk_ids: ^chunk_ids,
                 collection_id: collection_id
               }}} = Arcana.delete(doc.id, opts)

      assert collection_id == doc.collection_id

      refute Repo.get(Arcana.Document, doc.id)
      assert chunks.() == 0
    end

    test "an external cleanup exception is not misreported as a concurrent delete" do
      doc = ingest_doc("external cleanup raises after the delete commits")

      assert {:error,
              {:post_commit_graph_cleanup_failed,
               %{
                 reason: %Ecto.StaleEntryError{message: "external graph cleanup failed"},
                 chunk_ids: chunk_ids,
                 published_chunk_ids: chunk_ids,
                 collection_id: collection_id
               }}} =
               Arcana.delete(doc.id,
                 repo: Repo,
                 graph: true,
                 graph_store: Arcana.RaisingDeleteGraphStore
               )

      assert chunk_ids != []
      assert collection_id == doc.collection_id
      refute Repo.get(Arcana.Document, doc.id)
    end

    test "post-commit context can replay graph deletion after the document is gone" do
      doc = ingest_doc("retry external graph cleanup")

      assert {:error,
              {:post_commit_graph_cleanup_failed,
               %{
                 reason: :delete_boom,
                 chunk_ids: chunk_ids,
                 published_chunk_ids: published_chunk_ids,
                 collection_id: collection_id
               }}} =
               Arcana.delete(doc.id,
                 repo: Repo,
                 graph: true,
                 graph_store: Arcana.FailingDeleteGraphStore
               )

      refute Repo.get(Arcana.Document, doc.id)

      assert :ok =
               GraphStore.delete_by_chunks(chunk_ids,
                 repo: Repo,
                 graph_store: {Arcana.FailingDeleteGraphStore, delete_failure: :ok},
                 published_chunk_ids: published_chunk_ids
               )

      assert :ok =
               GraphStore.sweep_orphans(collection_id,
                 repo: Repo,
                 graph_store: {Arcana.FailingDeleteGraphStore, delete_failure: :ok}
               )
    end

    test "external cleanup exits and throws retain post-commit recovery context" do
      for {failure, expected_reason} <- [
            exit: :external_cleanup_exit,
            throw: {:throw, :external_cleanup_throw}
          ] do
        doc = ingest_doc("external cleanup #{failure}")

        assert {:error,
                {:post_commit_graph_cleanup_failed,
                 %{
                   reason: ^expected_reason,
                   chunk_ids: chunk_ids,
                   published_chunk_ids: chunk_ids,
                   collection_id: collection_id
                 }}} =
                 Arcana.delete(doc.id,
                   repo: Repo,
                   graph: true,
                   graph_store: {Arcana.RaisingDeleteGraphStore, cleanup_failure: failure}
                 )

        assert chunk_ids != []
        assert collection_id == doc.collection_id
        refute Repo.get(Arcana.Document, doc.id)
      end
    end
  end
end
