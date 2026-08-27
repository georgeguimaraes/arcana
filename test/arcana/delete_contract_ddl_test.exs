defmodule Arcana.DeleteContractDDLTest do
  @moduledoc """
  The `Arcana.delete/2` cases that need a host table pointing at
  `arcana_documents`.

  `async: false` deliberately. Adding a foreign key onto `arcana_documents`
  takes a `ShareRowExclusiveLock` on it, and the sandbox holds that until the
  test's transaction ends rather than just for the DDL. That conflicts with
  the `RowExclusiveLock` every document insert takes, so running these
  alongside the async suite blocks any concurrent test that writes documents -
  contention rather than deadlock, but a suite-wide serialization point and
  one more way a loaded CI run drifts toward the ownership timeout.

  Table names are unique per test for the same reason a shared `host_refs`
  would eventually collide.
  """
  use Arcana.DataCase, async: false

  alias Ecto.Adapters.SQL

  defp ingest_doc do
    {:ok, doc} = Arcana.ingest("Elixir runs on the BEAM.", repo: Repo)
    doc
  end

  defp reference_document(table, doc, column_opts \\ "") do
    SQL.query!(
      Repo,
      "CREATE TABLE #{table} (id serial primary key, " <>
        "document_id uuid #{column_opts} REFERENCES arcana_documents(id))",
      []
    )

    SQL.query!(Repo, "INSERT INTO #{table} (document_id) VALUES ($1)", [
      Ecto.UUID.dump!(doc.id)
    ])
  end

  test "a foreign key violation is an error tuple, not an exception" do
    doc = ingest_doc()
    reference_document("host_refs_fk", doc)

    assert {:error, reason} = Arcana.delete(doc.id, repo: Repo)

    refute reason == :not_found, "a constraint violation is not a missing document"

    assert Repo.get(Arcana.Document, doc.id),
           "the document must survive a failed delete"
  end

  test "a not-null violation from a host table is a tuple too" do
    # Ecto only turns fk/unique/check/exclusion codes into Ecto.ConstraintError.
    # ON DELETE SET NULL against a NOT NULL column raises 23502 instead, and it
    # is squarely "another table pointing at the document", which the docs
    # promise a tuple for. Rescuing only ConstraintError let this one escape.
    doc = ingest_doc()

    SQL.query!(
      Repo,
      "CREATE TABLE host_refs_nn (id serial primary key, " <>
        "document_id uuid NOT NULL REFERENCES arcana_documents(id) ON DELETE SET NULL)",
      []
    )

    SQL.query!(Repo, "INSERT INTO host_refs_nn (document_id) VALUES ($1)", [
      Ecto.UUID.dump!(doc.id)
    ])

    assert {:error, %Postgrex.Error{}} = Arcana.delete(doc.id, repo: Repo)

    assert Repo.get(Arcana.Document, doc.id)
  end

  test "a database failure ends the caller's transaction, as documented" do
    # Not a defect being pinned, a limitation being held to. Postgres aborts
    # the surrounding transaction on error, so no return value can make this
    # recoverable. The docs say so; this keeps them true.
    doc = ingest_doc()
    reference_document("host_refs_txn", doc)

    assert {:error, :rollback} =
             Repo.transaction(fn -> Arcana.delete(doc.id, repo: Repo) end)
  end
end
