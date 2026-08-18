defmodule Arcana.VectorStore.PgvectorIndexPathTest do
  @moduledoc """
  Covers vector search when the planner actually uses the HNSW index.

  Every other search test runs against a handful of rows, where a clean heap
  seq-scans, so none of them ever touched the index that ships to production.
  `enable_indexscan: "off"` on the test repo makes that explicit rather than
  accidental (see config/test.exs), which leaves this file as the only thing
  standing between a broken index and a green CI run.

  `async: false` on purpose. ExUnit runs sync tests once the async ones are
  done, so nothing else holds uncommitted rows in the index while this runs.
  That matters: concurrent in-flight entries at the same distance are what
  exhaust `hnsw.ef_search` and make an index scan return nothing, which is the
  flake config/test.exs exists to avoid. Forcing the index here without that
  isolation would just reintroduce it.
  """
  use Arcana.DataCase, async: false

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.VectorStore.Pgvector
  alias Ecto.Adapters.SQL

  @query_vector [1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381)

  setup do
    # Undo the repo-wide override for this connection only, and price a seq scan
    # out of contention so the planner has to reach for the index.
    SQL.query!(Repo, "SET LOCAL enable_indexscan = on", [])
    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])
    :ok
  end

  defp normalize(v) do
    magnitude = :math.sqrt(Enum.reduce(v, 0.0, &(&1 * &1 + &2)))
    Enum.map(v, &(&1 / magnitude))
  end

  defp seed_chunks do
    {:ok, collection} = Collection.get_or_create("index-path", Repo)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        content: "c",
        status: :completed,
        collection_id: collection.id
      })
      |> Repo.insert()

    for {text, vec} <- [
          {"nearest", @query_vector},
          {"further", [0.8, 0.2, 0.0] ++ List.duplicate(0.0, 381)}
        ] do
      {:ok, _} =
        %Chunk{}
        |> Chunk.changeset(%{text: text, embedding: normalize(vec), document_id: doc.id})
        |> Repo.insert()
    end
  end

  test "search returns the right rows through an HNSW index scan" do
    seed_chunks()

    # Assert the plan first. Without this the test could quietly seq-scan and
    # "pass" while covering nothing, which is exactly how the index path went
    # unexercised in the first place.
    %{rows: rows} =
      SQL.query!(
        Repo,
        "EXPLAIN (COSTS OFF) SELECT id FROM arcana_chunks " <>
          "ORDER BY embedding <=> $1::vector LIMIT 10",
        [normalize(@query_vector)]
      )

    plan = rows |> List.flatten() |> Enum.join("\n")

    assert plan =~ "Index Scan using arcana_chunks_embedding_idx",
           "expected an HNSW index scan, got:\n#{plan}"

    results = Pgvector.search("index-path", normalize(@query_vector), repo: Repo, limit: 10)

    assert length(results) == 2,
           "the index path lost rows that are visible to this transaction"

    assert hd(results).metadata[:text] == "nearest"
  end
end
