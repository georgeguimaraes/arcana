defmodule Arcana.ChunkSizingReachesIngestTest do
  @moduledoc """
  The sizing options have to survive the trip through the public API.

  Both ingest paths hand the chunker a `Keyword.take/2` whitelist, and a new
  option that isn't on it is dropped without a word. Testing
  `Chunker.Default.chunk/2` directly passes either way, so these go through
  `Arcana.ingest/2` and `Arcana.ingest_file/2` instead.
  """
  use Arcana.DataCase, async: true

  @cap 200

  setup do
    put_arcana_env(:embedder, fn _text -> {:ok, List.duplicate(0.1, 384)} end)
    text = String.duplicate("Sentence about refunds and warranty terms here. ", 200)
    {:ok, text: text}
  end

  defp largest_stored_chunk do
    Repo.all(Arcana.Chunk) |> Enum.map(&byte_size(&1.text)) |> Enum.max()
  end

  test "max_chunk_chars reaches the chunker through ingest/2", %{text: text} do
    assert {:ok, _doc} =
             Arcana.ingest(text, repo: Repo, collection: "sizing-text", max_chunk_chars: @cap)

    assert largest_stored_chunk() <= @cap,
           "the cap was dropped by the chunk-option whitelist"
  end

  test "max_chunk_chars reaches the chunker through ingest_file/2", %{text: text} do
    path = Path.join(System.tmp_dir!(), "arcana-sizing-#{System.unique_integer([:positive])}.txt")
    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, _doc} =
             Arcana.ingest_file(path,
               repo: Repo,
               collection: "sizing-file",
               max_chunk_chars: @cap
             )

    assert largest_stored_chunk() <= @cap,
           "the file path has its own whitelist and needs the option too"
  end

  test "chars_per_token reaches the chunker through ingest/2", %{text: text} do
    # A smaller assumed ratio means a smaller effective character budget, so
    # the same text has to come back as more chunks.
    assert {:ok, generous} =
             Arcana.ingest(text, repo: Repo, collection: "cpt-4", chars_per_token: 4)

    assert {:ok, dense} =
             Arcana.ingest(text, repo: Repo, collection: "cpt-1", chars_per_token: 1)

    assert dense.chunk_count > generous.chunk_count,
           "chars_per_token was dropped: both ingests chunked identically"
  end
end
