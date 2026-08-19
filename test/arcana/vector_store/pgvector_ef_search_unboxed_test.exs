defmodule Arcana.VectorStore.PgvectorEfSearchUnboxedTest do
  @moduledoc """
  Runs `:hnsw_ef_search` outside the sandbox, which is the only way to reach the
  branch production takes.

  `with_ef_search/3` opens a transaction, and every sandboxed test is already
  inside one, so `repo.transaction/1` joins there instead of starting a real one.
  What this test uniquely covers is that the fresh-transaction path works at all:
  that opening one, setting the GUC on it, and unwrapping the result actually
  hands the caller a list.

  Measured, so the value here is not overstated: deleting the `{:ok, result}`
  unwrap fails this test AND three of the sandboxed ones, because Ecto returns
  `{:ok, _}` from a joined transaction too. So it is not the only guard against
  that particular bug - it is the only one exercising the code path production
  takes.

  `async: false` and unboxed, so its writes commit: everything it inserts is
  named uniquely and torn down explicitly.
  """
  use Arcana.DataCase, async: false

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.VectorStore.Pgvector
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  @embedding List.duplicate(0.0, 383) ++ [1.0]
  @collection "ef-unboxed-fixture"

  test "returns a plain list when it has to open its own transaction" do
    Sandbox.unboxed_run(Repo, fn ->
      cleanup()

      try do
        {:ok, collection} = Collection.get_or_create(@collection, Repo)

        {:ok, doc} =
          %Document{}
          |> Document.changeset(%{
            content: "c",
            status: :completed,
            collection_id: collection.id
          })
          |> Repo.insert()

        {:ok, _} =
          %Chunk{}
          |> Chunk.changeset(%{text: "unboxed", embedding: @embedding, document_id: doc.id})
          |> Repo.insert()

        refute Repo.in_transaction?(),
               "precondition: this must run outside a transaction, or it proves nothing"

        results = Pgvector.search(@collection, @embedding, repo: Repo, hnsw_ef_search: 77)

        assert is_list(results),
               "search must return a list, not the transaction's {:ok, _}: got #{inspect(results)}"

        assert length(results) == 1
      after
        cleanup()
      end
    end)
  end

  defp cleanup do
    SQL.query!(
      Repo,
      "DELETE FROM arcana_chunks WHERE document_id IN (" <>
        "SELECT d.id FROM arcana_documents d JOIN arcana_collections c " <>
        "ON d.collection_id = c.id WHERE c.name = $1)",
      [@collection]
    )

    SQL.query!(
      Repo,
      "DELETE FROM arcana_documents WHERE collection_id IN " <>
        "(SELECT id FROM arcana_collections WHERE name = $1)",
      [@collection]
    )

    SQL.query!(Repo, "DELETE FROM arcana_collections WHERE name = $1", [@collection])
  end
end
