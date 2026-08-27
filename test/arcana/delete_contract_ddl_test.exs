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

  test "a database failure ends a caller's transaction that set no savepoint" do
    # Postgres aborts to the nearest savepoint, and with none open that is the
    # whole transaction. Not a defect, but see the next test: it is the absence
    # of a savepoint doing this, not something delete/2 cannot be recovered
    # from, which is what the docs used to imply.
    doc = ingest_doc()
    reference_document("host_refs_txn", doc)

    assert {:error, :rollback} =
             Repo.transaction(fn -> Arcana.delete(doc.id, repo: Repo) end)
  end

  test "a savepoint lets the caller survive a database failure" do
    # The documented recovery. Worth a test because the docs previously called
    # this unrecoverable and told people to restructure their code instead.
    doc = ingest_doc()
    reference_document("host_refs_sp", doc)

    result =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT before_delete")

        outcome = Arcana.delete(doc.id, repo: Repo)

        Repo.query!("ROLLBACK TO SAVEPOINT before_delete")

        # The point: still usable after the failure.
        {outcome, Repo.aggregate(Arcana.Document, :count)}
      end)

    assert {:ok, {{:error, _reason}, count}} = result
    assert count >= 1, "the caller's transaction committed and the document is still there"
  end

  test "a savepoint works with the graph enabled too" do
    # The graph-off version above passed while this one failed, because the
    # sweeping branch wraps the delete in the graph write lock and that used to
    # open a nested Ecto transaction. DBConnection marks the connection aborted
    # when work inside one fails, which refused the ROLLBACK TO SAVEPOINT and
    # took the caller's pooled connection with it. Since every ingest lands in
    # a collection, "graph enabled" was the whole audience for the documented
    # recipe.
    extractor = fn _t, _o -> {:ok, [%{name: "Tau", type: "concept"}]} end

    {:ok, doc} =
      Arcana.ingest("tau content",
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        collection: "savepoint-graph-on"
      )

    reference_document("host_refs_sp_graph", doc)

    result =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT before_delete")

        outcome = Arcana.delete(doc.id, repo: Repo, graph: true)

        Repo.query!("ROLLBACK TO SAVEPOINT before_delete")

        {outcome, Repo.aggregate(Arcana.Document, :count)}
      end)

    assert {:ok, {{:error, _reason}, count}} = result
    assert count >= 1, "the caller's transaction survived and committed"
  end

  test "a savepoint recovers even a sweep that raises" do
    # The docs claim the recipe covers every failure the built-in stores can
    # produce, this being the least obvious one. It only holds because
    # with_write_lock/3 no longer opens a nested transaction; before that the
    # ROLLBACK TO SAVEPOINT was refused here too.
    extractor = fn _t, _o -> {:ok, [%{name: "Omega", type: "concept"}]} end

    {:ok, doc} =
      Arcana.ingest("omega content",
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        collection: "savepoint-sweep-raises"
      )

    entity = Repo.one!(from(e in Arcana.Graph.Entity, where: e.name == "Omega"))

    SQL.query!(
      Repo,
      "CREATE TABLE host_entity_refs_sp (id serial primary key, " <>
        "entity_id uuid REFERENCES arcana_graph_entities(id))",
      []
    )

    SQL.query!(Repo, "INSERT INTO host_entity_refs_sp (entity_id) VALUES ($1)", [
      Ecto.UUID.dump!(entity.id)
    ])

    result =
      Repo.transaction(fn ->
        Repo.query!("SAVEPOINT before_delete")

        outcome = Arcana.delete(doc.id, repo: Repo, graph: true)

        Repo.query!("ROLLBACK TO SAVEPOINT before_delete")

        {outcome, Repo.aggregate(Arcana.Document, :count)}
      end)

    assert {:ok, {{:error, %Postgrex.Error{}}, count}} = result
    assert count >= 1, "the caller's transaction survived and committed"
  end

  test "a sweep that raises on a host constraint is a tuple, not an exception" do
    # sweep_orphans/2 deletes with repo.delete_all/1, which skips changeset
    # constraint mapping, so a host row referencing an orphaned entity raises a
    # bare Postgrex.Error. It reports as a database failure rather than
    # :sweep_failed - folding it into :sweep_failed means rescuing inside the
    # write lock's nested transaction, which is already aborted by then and
    # turns the error into a MatchError. The docs say which one you get.
    extractor = fn _t, _o -> {:ok, [%{name: "Sigma", type: "concept"}]} end

    {:ok, doc} =
      Arcana.ingest("sigma content",
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        collection: "sweep-host-fk"
      )

    entity = Repo.one!(from(e in Arcana.Graph.Entity, where: e.name == "Sigma"))

    SQL.query!(
      Repo,
      "CREATE TABLE host_entity_refs (id serial primary key, " <>
        "entity_id uuid REFERENCES arcana_graph_entities(id))",
      []
    )

    SQL.query!(Repo, "INSERT INTO host_entity_refs (entity_id) VALUES ($1)", [
      Ecto.UUID.dump!(entity.id)
    ])

    assert {:error, %Postgrex.Error{}} = Arcana.delete(doc.id, repo: Repo, graph: true)

    assert Repo.get(Arcana.Document, doc.id), "the document comes back"
  end
end
