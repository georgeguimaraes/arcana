defmodule Arcana.MigrationTest do
  @moduledoc """
  Runs the versioned migrations against a real database.

  Not async and not sandboxed: these run DDL and inspect the catalog, which
  a sandbox transaction would roll back out from under the assertions. Each
  test works in its own Postgres schema so they can't collide.
  """
  use ExUnit.Case, async: false

  doctest Arcana.Migration.Dimensions

  alias Arcana.MigrationRepo, as: Repo
  alias Ecto.Adapters.Postgres
  alias Ecto.Adapters.SQL

  setup_all do
    # A database of its own: these tests create and drop Arcana's tables,
    # which would wreck the shared one every other suite depends on.
    _ = Postgres.storage_up(Repo.config())
    {:ok, pid} = Repo.start_link()

    on_exit(fn ->
      # By the time on_exit runs the repo supervisor is often already on its
      # way down, and Supervisor.stop then exits. The reason nests
      # differently depending on how far along it got - two attempts at
      # matching the shape both passed locally and failed on CI - and none
      # of it is actionable: the suite is over either way, and a callback
      # that exits invalidates every test in the file. So wait for the
      # process to actually be gone and let the exit itself pass.
      ref = Process.monitor(pid)

      try do
        Supervisor.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        5_000 -> :ok
      end
    end)

    :ok
  end

  setup do
    # Each test starts from nothing, so version detection is real rather
    # than inherited from whatever ran before.
    for table <- ~w(arcana_graph_communities arcana_graph_entity_mentions
                    arcana_graph_relationships arcana_graph_entities
                    arcana_evaluation_runs arcana_evaluation_test_case_chunks
                    arcana_evaluation_test_cases arcana_chunks
                    arcana_documents arcana_collections schema_migrations) do
      SQL.query!(Repo, "DROP TABLE IF EXISTS #{table} CASCADE", [])
    end

    :ok
  end

  # up/1 requires :dimensions now. These tests are about versioning, not the
  # number, so the helper supplies one unless a test cares.
  defp migrate(module, opts \\ []) do
    run(module, :up, Keyword.put_new(opts, :dimensions, 384))
  end

  defp migrate_down(module, opts), do: run(module, :down, opts)

  # Ecto.Migration's DSL only works inside a running migration, and the
  # Migrator runs it in its own process, so the call is inlined into a
  # generated module rather than passed as a closure. Both directions go
  # through Migrator.up/4: `down` here means "the thing this migration
  # does is call Arcana.Migration.down/1", not a rollback of it.
  defp run(module, direction, opts) do
    name = :"Elixir.MigTest#{System.unique_integer([:positive])}"

    body =
      quote do
        use Ecto.Migration

        def up, do: unquote(module).unquote(direction)(unquote(Macro.escape(opts)))
      end

    Module.create(name, body, Macro.Env.location(__ENV__))
    Ecto.Migrator.up(Repo, System.unique_integer([:positive]), name, log: false)
  end

  # 'n' = SET NULL (what :nilify_all produces), 'r' = RESTRICT.
  defp collection_fk_rule do
    %{rows: [[rule]]} =
      SQL.query!(
        Repo,
        "SELECT confdeltype FROM pg_constraint " <>
          "WHERE conname = 'arcana_documents_collection_id_fkey' " <>
          "AND conrelid = 'arcana_documents'::regclass AND contype = 'f'",
        []
      )

    rule
  end

  # COMMENT ON TABLE takes no bind parameters, so the literal is escaped the
  # way Postgres wants: a single quote doubled.
  defp set_table_comment(comment) do
    escaped = String.replace(comment, "'", "''")
    SQL.query!(Repo, "COMMENT ON TABLE arcana_documents IS '#{escaped}'", [])
  end

  defp tables do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = current_schema()",
        []
      )

    List.flatten(rows)
  end

  defp create_graph_entities_table do
    SQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS vector", [])

    SQL.query!(
      Repo,
      """
      CREATE TABLE arcana_graph_entities (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name varchar(255) NOT NULL,
        type varchar(255) NOT NULL,
        description text,
        embedding vector(384),
        metadata jsonb DEFAULT '{}',
        chunk_id uuid,
        collection_id uuid,
        inserted_at timestamp(0) NOT NULL DEFAULT now(),
        updated_at timestamp(0) NOT NULL DEFAULT now()
      )
      """,
      []
    )
  end

  defp create_collections_table do
    SQL.query!(
      Repo,
      """
      CREATE TABLE arcana_collections (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name varchar(255) NOT NULL,
        description text,
        inserted_at timestamp(0) NOT NULL DEFAULT now(),
        updated_at timestamp(0) NOT NULL DEFAULT now()
      )
      """,
      []
    )
  end

  defp index_valid?(name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT i.indisvalid AND i.indisready FROM pg_index i " <>
          "JOIN pg_class ic ON ic.oid = i.indexrelid WHERE ic.relname = $1",
        [name]
      )

    match?([[true]], rows)
  end

  # The OID identifies the physical index, so a drop-and-recreate changes it.
  defp index_identity(name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT i.indexrelid, i.indisunique, i.indpred IS NOT NULL, " <>
          "0 = ANY(i.indkey::int2[]) FROM pg_index i " <>
          "JOIN pg_class ic ON ic.oid = i.indexrelid WHERE ic.relname = $1",
        [name]
      )

    case rows do
      [[oid, unique, partial, expression]] ->
        %{oid: oid, unique: unique, partial: partial, expression: expression}

      _ ->
        nil
    end
  end

  defp index_columns(name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT array_agg(a.attname::text ORDER BY k.ord) FROM pg_index i " <>
          "JOIN pg_class ic ON ic.oid = i.indexrelid " <>
          "JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true " <>
          "JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum " <>
          "WHERE ic.relname = $1 GROUP BY i.indexrelid",
        [name]
      )

    case rows do
      [[cols]] -> cols
      _ -> nil
    end
  end

  # A mention pair needs a real entity and chunk behind it, and the chunk needs
  # a document. The two rows differ only in inserted_at, so the dedup has an
  # unambiguous oldest row to keep.
  defp seed_duplicate_mentions do
    %{rows: [[doc]]} =
      SQL.query!(
        Repo,
        "INSERT INTO arcana_documents (id, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), now(), now()) RETURNING id",
        []
      )

    %{rows: [[chunk]]} =
      SQL.query!(
        Repo,
        "INSERT INTO arcana_chunks (id, text, embedding, document_id, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), 'x', array_fill(0::real, ARRAY[384])::vector, $1, " <>
          "now(), now()) RETURNING id",
        [doc]
      )

    %{rows: [[entity]]} =
      SQL.query!(
        Repo,
        "INSERT INTO arcana_graph_entities (id, name, type, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), 'e', 't', now(), now()) RETURNING id",
        []
      )

    SQL.query!(
      Repo,
      "INSERT INTO arcana_graph_entity_mentions " <>
        "(id, entity_id, chunk_id, context, inserted_at, updated_at) VALUES " <>
        "(gen_random_uuid(), $1, $2, 'older', now() - interval '1 day', now()), " <>
        "(gen_random_uuid(), $1, $2, 'newer', now(), now())",
      [entity, chunk]
    )
  end

  defp mention_contexts do
    %{rows: rows} =
      SQL.query!(Repo, "SELECT context FROM arcana_graph_entity_mentions", [])

    List.flatten(rows)
  end

  defp unique_index?(name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT i.indisunique FROM pg_index i " <>
          "JOIN pg_class ic ON ic.oid = i.indexrelid " <>
          "WHERE ic.relname = $1",
        [name]
      )

    match?([[true]], rows)
  end

  defp embedding_type(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid " <>
          "WHERE c.relname = $1 AND a.attname = 'embedding' AND a.attnum > 0",
        [table]
      )

    case rows do
      [[t]] -> t
      _ -> nil
    end
  end

  defp columns(table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_name = $1 AND table_schema = current_schema()",
        [table]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp table_exists?(table), do: MapSet.size(columns(table)) > 0

  describe "Arcana.Migration" do
    test "creates the core schema and records a version" do
      migrate(Arcana.Migration)

      for table <- ~w(arcana_collections arcana_documents arcana_chunks
                      arcana_evaluation_test_cases arcana_evaluation_runs) do
        assert table_exists?(table), "#{table} was not created"
      end

      assert Arcana.Migration.recorded_version(Repo) == Arcana.Migration.current_version()
    end

    test "creates reference_answer, which no installer template ever did" do
      migrate(Arcana.Migration)

      assert "reference_answer" in columns("arcana_evaluation_test_cases"),
             "Arcana.Evaluation.TestCase reads this column, so a fresh install needs it"
    end

    test "honors :dimensions for the chunk embedding" do
      migrate(Arcana.Migration, dimensions: 1024)

      %{rows: [[type]]} =
        SQL.query!(
          Repo,
          "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a " <>
            "WHERE a.attrelid = 'arcana_chunks'::regclass AND a.attname = 'embedding'",
          []
        )

      assert type == "vector(1024)"
    end

    test "running it twice is a no-op rather than an error" do
      migrate(Arcana.Migration)
      migrate(Arcana.Migration)

      assert Arcana.Migration.recorded_version(Repo) == Arcana.Migration.current_version()
    end

    test "converges an install that predates versioning" do
      # Exactly the shape an older Arcana left behind: the tables exist, no
      # version is recorded, and the column added by a later release is
      # missing. Adoption must add it without touching the data.
      SQL.query!(
        Repo,
        """
        CREATE TABLE arcana_evaluation_test_cases (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          question text NOT NULL,
          source varchar(255) NOT NULL DEFAULT 'synthetic',
          inserted_at timestamp(0) NOT NULL DEFAULT now(),
          updated_at timestamp(0) NOT NULL DEFAULT now()
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        "INSERT INTO arcana_evaluation_test_cases (question) VALUES ('kept?')",
        []
      )

      assert Arcana.Migration.recorded_version(Repo) == 0
      refute "reference_answer" in columns("arcana_evaluation_test_cases")

      migrate(Arcana.Migration)

      assert "reference_answer" in columns("arcana_evaluation_test_cases")
      assert Arcana.Migration.recorded_version(Repo) == Arcana.Migration.current_version()

      %{rows: [[question]]} =
        SQL.query!(Repo, "SELECT question FROM arcana_evaluation_test_cases", [])

      assert question == "kept?", "adoption must not drop existing rows"
    end

    test "converges the collection FK an old installer left as SET NULL" do
      # Every installer template shipped before the versioned migrations
      # emitted on_delete: :nilify_all here, so deleting a collection
      # detached its documents instead of refusing. Adoption has to swap the
      # rule, or the same delete behaves differently on an old database than
      # on a fresh one.
      SQL.query!(Repo, "CREATE EXTENSION IF NOT EXISTS vector", [])

      SQL.query!(
        Repo,
        """
        CREATE TABLE arcana_collections (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          name varchar(255) NOT NULL,
          description text,
          inserted_at timestamp(0) NOT NULL DEFAULT now(),
          updated_at timestamp(0) NOT NULL DEFAULT now()
        )
        """,
        []
      )

      SQL.query!(
        Repo,
        """
        CREATE TABLE arcana_documents (
          id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
          content text,
          content_type varchar(255) DEFAULT 'text/plain',
          source_id varchar(255),
          file_path varchar(255),
          metadata jsonb DEFAULT '{}',
          status varchar(255) DEFAULT 'pending',
          error text,
          chunk_count integer DEFAULT 0,
          collection_id uuid REFERENCES arcana_collections(id) ON DELETE SET NULL,
          inserted_at timestamp(0) NOT NULL DEFAULT now(),
          updated_at timestamp(0) NOT NULL DEFAULT now()
        )
        """,
        []
      )

      assert collection_fk_rule() == "n", "precondition: the old rule is SET NULL"

      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('tenant')", [])

      SQL.query!(
        Repo,
        "INSERT INTO arcana_documents (content, collection_id) " <>
          "SELECT 'kept', id FROM arcana_collections",
        []
      )

      migrate(Arcana.Migration)

      assert collection_fk_rule() == "r",
             "adoption must swap the collection FK to RESTRICT"

      # And it actually bites: the delete is refused rather than detaching.
      assert_raise Postgrex.Error, fn ->
        SQL.query!(Repo, "DELETE FROM arcana_collections", [])
      end

      %{rows: [[content]]} = SQL.query!(Repo, "SELECT content FROM arcana_documents", [])
      assert content == "kept", "converging the constraint must not touch rows"
    end

    # A comment arcana doesn't own must never be read as a version. The
    # marker is anchored, so only an exact match counts.
    for {label, comment} <- [
          {"a host's own description", "Documents ingested by our pipeline"},
          {"prose that happens to contain the marker", "see arcana:2 for details"},
          {"a bare integer, which is what Oban stores", "1"},
          {"the marker with trailing junk", "arcana:1 (do not edit)"},
          {"an empty comment", ""}
        ] do
      test "#{label} does not read as a version" do
        migrate(Arcana.Migration)
        assert Arcana.Migration.recorded_version(Repo) == 1

        set_table_comment(unquote(comment))

        assert Arcana.Migration.recorded_version(Repo) == 0,
               "#{unquote(label)} was mistaken for a recorded version"
      end
    end

    test "the marker parses with surrounding whitespace" do
      migrate(Arcana.Migration)
      set_table_comment("  arcana:1\n")

      assert Arcana.Migration.recorded_version(Repo) == 1
    end

    test "down/1 refuses to roll back when the marker is gone but the tables aren't" do
      migrate(Arcana.Migration)
      assert Arcana.Migration.recorded_version(Repo) == 1

      # What a host comment on the version table looks like afterwards.
      set_table_comment("Documents ingested by our pipeline")
      assert Arcana.Migration.recorded_version(Repo) == 0

      assert_raise RuntimeError, ~r/can't tell which version is applied/, fn ->
        migrate_down(Arcana.Migration, [])
      end

      # Refusing means refusing: the tables are still there.
      assert "arcana_documents" in tables()
      assert "arcana_chunks" in tables()
    end

    test "down/1 refuses when the version table is gone but its siblings remain" do
      migrate(Arcana.Migration)

      # A partial or hand-modified install: the version table is gone, so
      # there is nowhere to read a marker, but other Arcana tables are still
      # here and a rollback does have something to do.
      SQL.query!(Repo, "DROP TABLE arcana_documents CASCADE", [])

      assert Arcana.Migration.recorded_version(Repo) == 0
      assert "arcana_collections" in tables()

      err =
        assert_raise RuntimeError, ~r/can't tell which version is applied/, fn ->
          migrate_down(Arcana.Migration, [])
        end

      # It can't offer the COMMENT recovery, because the table to comment on
      # is the one that's missing.
      assert err.message =~ "is not among them"
      assert err.message =~ "arcana_collections"
      refute err.message =~ "COMMENT ON TABLE"

      assert "arcana_collections" in tables(), "refusing must leave them alone"
    end

    test "a view sharing the version table's name is not mistaken for an install" do
      refute "arcana_documents" in tables()
      SQL.query!(Repo, "CREATE VIEW arcana_documents AS SELECT 1 AS id", [])
      on_exit(fn -> SQL.query!(Repo, "DROP VIEW IF EXISTS arcana_documents", []) end)

      # relkind is constrained to tables, so this stays a quiet no-op rather
      # than refusing with recovery SQL that could not work on a view.
      assert :ok = migrate_down(Arcana.Migration, [])
    end

    test "down/1 is a quiet no-op when nothing is installed" do
      # No tables at all, which is the one case version 0 legitimately means
      # "nothing to drop".
      refute "arcana_documents" in tables()

      assert :ok = migrate_down(Arcana.Migration, [])
    end

    test "restoring the marker makes the rollback work again" do
      migrate(Arcana.Migration)
      set_table_comment("clobbered by a schema-doc tool")

      assert_raise RuntimeError, ~r/can't tell which version is applied/, fn ->
        migrate_down(Arcana.Migration, [])
      end

      # The error tells the operator to do exactly this.
      set_table_comment("arcana:1")

      assert :ok = migrate_down(Arcana.Migration, [])
      refute "arcana_documents" in tables()
    end

    test "up/1 requires :dimensions" do
      err =
        assert_raise ArgumentError, fn ->
          run(Arcana.Migration, :up, [])
        end

      assert err.message =~ "requires :dimensions"
      assert err.message =~ "Arcana.Embedder.dimensions"
      assert embedding_type("arcana_chunks") == nil, "nothing should be created"
    end

    for bad <- [0, -1, "384", 384.0] do
      test "up/1 rejects dimensions: #{inspect(bad)}" do
        assert_raise ArgumentError, ~r/:dimensions must be a positive integer/, fn ->
          run(Arcana.Migration, :up, dimensions: unquote(bad))
        end
      end
    end

    test "a dimension contradicting an existing column is refused, not ignored" do
      migrate(Arcana.Migration, dimensions: 384)
      assert embedding_type("arcana_chunks") == "vector(384)"

      # create_if_not_exists leaves the table alone, so without the check this
      # would report success and silently keep 384 while a fresh database
      # built from the same migration would get 1024.
      err =
        assert_raise ArgumentError, fn ->
          migrate(Arcana.Migration, dimensions: 1024)
        end

      assert err.message =~ "already vector(384)"
      assert err.message =~ "Pass dimensions: 384"
      assert embedding_type("arcana_chunks") == "vector(384)", "column must be untouched"
    end

    test "re-running with the matching dimension is fine" do
      migrate(Arcana.Migration, dimensions: 384)
      assert :ok = migrate(Arcana.Migration, dimensions: 384)
      assert embedding_type("arcana_chunks") == "vector(384)"
    end

    test "converge rebuilds a legacy index that has the right name and wrong shape" do
      # Exactly what an older installer template could leave behind: the name
      # Ecto would generate, but non-unique. create_if_not_exists matches on
      # the name, so without a shape check Postgres skips creation, reports
      # success, and the adopted database never gets the constraint.
      create_collections_table()

      SQL.query!(
        Repo,
        "CREATE INDEX arcana_collections_name_index ON arcana_collections (name)",
        []
      )

      refute unique_index?("arcana_collections_name_index"), "precondition: not unique"

      migrate(Arcana.Migration)

      assert unique_index?("arcana_collections_name_index"),
             "converge kept a non-unique index that shares the name"

      # And it actually constrains now.
      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])

      assert_raise Postgrex.Error, fn ->
        SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])
      end
    end

    test "a wrong-shaped index is rebuilt even when the version already matches" do
      # The regression this guards: converge runs from up/1, but the recreate
      # used to live inside change(1, :up, _), which is skipped once the
      # recorded version equals the target. The index was dropped and never
      # replaced, leaving the table with no index at all while the log claimed
      # a rebuild.
      migrate(Arcana.Migration)
      assert Arcana.Migration.recorded_version(Repo) == 1

      SQL.query!(Repo, "DROP INDEX arcana_collections_name_index", [])

      SQL.query!(
        Repo,
        "CREATE INDEX arcana_collections_name_index ON arcana_collections (name)",
        []
      )

      refute index_identity("arcana_collections_name_index").unique

      # Already at the target version, so change(1, :up, _) will not run.
      assert :ok = migrate(Arcana.Migration)

      identity = index_identity("arcana_collections_name_index")
      assert identity, "the index was dropped and never rebuilt"
      assert identity.unique, "rebuilt, but not as a unique index"

      # The migrated table has no default on id, unlike the hand-built one
      # the other tests use.
      insert =
        "INSERT INTO arcana_collections (id, name, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), 'x', now(), now())"

      SQL.query!(Repo, insert, [])

      assert_raise Postgrex.Error, fn -> SQL.query!(Repo, insert, []) end
    end

    test "converge rebuilds an index that shares the name but covers other columns" do
      # The column-list mismatch: same name, so create_if_not_exists skips it,
      # and it constrains the wrong column entirely.
      create_collections_table()

      SQL.query!(
        Repo,
        "CREATE UNIQUE INDEX arcana_collections_name_index ON arcana_collections (description)",
        []
      )

      assert index_columns("arcana_collections_name_index") == ["description"],
             "precondition: the index covers the wrong column"

      migrate(Arcana.Migration)

      assert index_columns("arcana_collections_name_index") == ["name"],
             "an index on the wrong column kept its name and was left in place"

      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])

      assert_raise Postgrex.Error, fn ->
        SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])
      end
    end

    test "a missing index over duplicates is refused with an explanation" do
      # The rebuild path checks for duplicates first, but an index that is
      # absent entirely went straight to CREATE UNIQUE INDEX, so a table whose
      # index was manually dropped produced a raw Postgrex unique violation
      # instead of the refusal this migration promises.
      migrate(Arcana.Migration)
      SQL.query!(Repo, "DROP INDEX arcana_collections_name_index", [])

      insert =
        "INSERT INTO arcana_collections (id, name, inserted_at, updated_at) " <>
          "VALUES (gen_random_uuid(), $1, now(), now())"

      SQL.query!(Repo, insert, ["dup"])
      SQL.query!(Repo, insert, ["dup"])

      err = assert_raise RuntimeError, fn -> migrate(Arcana.Migration) end

      assert err.message =~ "can't add the unique index arcana_collections_name_index"
      assert err.message =~ "It is missing, so nothing enforced uniqueness"
      assert err.message =~ ~s(["dup"])

      refute index_identity("arcana_collections_name_index"),
             "the refusal must not leave a half-built index behind"
    end

    test "rows with a NULL key column do not count as duplicates" do
      # Postgres treats NULLs as distinct in a unique index, so these never
      # collide and must not block the migration.
      create_graph_entities_table()

      SQL.query!(
        Repo,
        "CREATE INDEX arcana_graph_entities_name_collection_id_index " <>
          "ON arcana_graph_entities (name, collection_id)",
        []
      )

      SQL.query!(
        Repo,
        "INSERT INTO arcana_graph_entities (name, type) VALUES ('same','t'), ('same','t')",
        []
      )

      migrate(Arcana.Migration)
      assert :ok = migrate(Arcana.Graph.Migration)

      assert index_identity("arcana_graph_entities_name_collection_id_index").unique,
             "NULL collection_id rows were treated as duplicates and blocked the rebuild"
    end

    test "an invalid index of the right shape is rebuilt" do
      # A failed CREATE INDEX CONCURRENTLY leaves an index that is present and
      # correctly shaped but enforces nothing. Matching on shape alone treated
      # it as healthy and left the table unconstrained.
      migrate(Arcana.Migration)
      before = index_identity("arcana_collections_name_index")
      assert before.unique

      SQL.query!(
        Repo,
        "UPDATE pg_index SET indisvalid = false " <>
          "WHERE indexrelid = 'arcana_collections_name_index'::regclass",
        []
      )

      refute index_valid?("arcana_collections_name_index"), "precondition: invalid"

      assert :ok = migrate(Arcana.Migration)

      assert index_valid?("arcana_collections_name_index"),
             "an invalid index was treated as healthy and left in place"

      assert index_identity("arcana_collections_name_index").oid != before.oid,
             "it should have been rebuilt, not adopted"
    end

    test "a not-ready index of the right shape is rebuilt" do
      # indisready is the other half of usable: an index still being built is
      # present and shaped correctly but not yet enforcing anything.
      migrate(Arcana.Migration)
      before = index_identity("arcana_collections_name_index")

      SQL.query!(
        Repo,
        "UPDATE pg_index SET indisready = false " <>
          "WHERE indexrelid = 'arcana_collections_name_index'::regclass",
        []
      )

      refute index_valid?("arcana_collections_name_index"), "precondition: not ready"

      assert :ok = migrate(Arcana.Migration)

      assert index_valid?("arcana_collections_name_index"),
             "a not-ready index was treated as healthy and left in place"

      assert index_identity("arcana_collections_name_index").oid != before.oid,
             "it should have been rebuilt"
    end

    test "converge leaves a correctly-shaped index alone" do
      migrate(Arcana.Migration)
      before = index_identity("arcana_collections_name_index")
      assert before.unique

      assert :ok = migrate(Arcana.Migration)

      # Compare the OID, not just uniqueness: a drop-and-recreate would still
      # leave a unique index, so checking indisunique alone cannot fail on the
      # churn this test claims to guard against.
      assert index_identity("arcana_collections_name_index") == before,
             "the index was rebuilt when its shape already matched"
    end

    test "a partial unique index is rebuilt, since it only constrains some rows" do
      create_collections_table()

      SQL.query!(
        Repo,
        "CREATE UNIQUE INDEX arcana_collections_name_index ON arcana_collections (name) " <>
          "WHERE description IS NOT NULL",
        []
      )

      migrate(Arcana.Migration)

      identity = index_identity("arcana_collections_name_index")
      assert identity.unique
      refute identity.partial, "a partial index does not enforce uniqueness for every row"

      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])

      assert_raise Postgrex.Error, fn ->
        SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])
      end
    end

    test "an expression index under the same name is rebuilt" do
      create_collections_table()

      SQL.query!(
        Repo,
        "CREATE UNIQUE INDEX arcana_collections_name_index ON arcana_collections (lower(name))",
        []
      )

      migrate(Arcana.Migration)

      identity = index_identity("arcana_collections_name_index")
      refute identity.expression, "an expression index does not constrain the raw column"

      # Differing only by case is now allowed again, and exact duplicates are not.
      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('Dup')", [])
      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])

      assert_raise Postgrex.Error, fn ->
        SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('dup')", [])
      end
    end

    test "duplicates block the rebuild with the offending keys, changing nothing" do
      create_collections_table()

      SQL.query!(
        Repo,
        "CREATE INDEX arcana_collections_name_index ON arcana_collections (name)",
        []
      )

      SQL.query!(Repo, "INSERT INTO arcana_collections (name) VALUES ('same'), ('same')", [])

      err =
        assert_raise RuntimeError, ~r/can't add the unique index/, fn ->
          migrate(Arcana.Migration)
        end

      assert err.message =~ ~s(["same"])
      assert err.message =~ "cascades to rows it does not own"

      # Nothing was changed: the legacy index survives and the rows are intact.
      refute index_identity("arcana_collections_name_index").unique

      %{rows: [[count]]} = SQL.query!(Repo, "SELECT count(*) FROM arcana_collections", [])
      assert count == 2
    end

    test "refuses to run against a database a newer release migrated" do
      migrate(Arcana.Migration)

      # An older Arcana meeting a newer schema must say so rather than
      # returning :ok and leaving the caller to find out later.
      SQL.query!(Repo, "COMMENT ON TABLE arcana_documents IS 'arcana:99'", [])

      assert_raise ArgumentError, ~r/does not\s+know about/, fn ->
        migrate(Arcana.Migration)
      end
    end

    test "refuses a rollback target outside the supported range" do
      migrate(Arcana.Migration)

      assert_raise ArgumentError, ~r/rollback target/, fn ->
        migrate_down(Arcana.Migration, version: -1)
      end

      # It refused before running anything, so the tables are still here.
      assert table_exists?("arcana_documents")
    end

    test "refuses a version this release doesn't know about" do
      assert_raise ArgumentError, ~r/newer than this release/, fn ->
        migrate(Arcana.Migration, version: 99)
      end
    end
  end

  describe "prefix" do
    test "installs into a Postgres schema and leaves the default one alone" do
      SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "tenant_a" CASCADE), [])
      on_exit(fn -> SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "tenant_a" CASCADE), []) end)

      migrate(Arcana.Migration, prefix: "tenant_a")

      assert Arcana.Migration.recorded_version(Repo, prefix: "tenant_a") ==
               Arcana.Migration.current_version()

      # The default schema must be untouched: a prefixed install is a
      # separate tenant, not a second copy of the same one.
      assert Arcana.Migration.recorded_version(Repo) == 0
      assert columns("arcana_documents") == MapSet.new()

      %{rows: [[count]]} =
        SQL.query!(
          Repo,
          "SELECT count(*) FROM information_schema.tables " <>
            "WHERE table_schema = 'tenant_a' AND table_name = 'arcana_documents'",
          []
        )

      assert count == 1
    end

    test "a prefix containing a double quote is refused by Ecto's DDL" do
      # The escaping in quoted/1 does run: maybe_create_schema/2 issues
      # CREATE SCHEMA IF NOT EXISTS "ten""ant" through it before any table
      # is built. Ecto then rejects the same prefix at table/2, and the
      # migration transaction rolls the schema back, so nothing survives.
      assert_raise ArgumentError, ~r/is not permitted/, fn ->
        migrate(Arcana.Migration, prefix: ~s(ten"ant))
      end

      %{rows: [[count]]} =
        SQL.query!(
          Repo,
          "SELECT count(*) FROM information_schema.schemata WHERE schema_name = $1",
          [~s(ten"ant)]
        )

      assert count == 0, "the rolled-back CREATE SCHEMA should leave nothing behind"
    end

    test "a prefix containing a single quote installs cleanly" do
      # Postgres permits it, and Ecto's DDL doesn't reject it the way it
      # rejects a double quote, so it reaches the raw SQL. Escaping an
      # identifier is not the escaping a SQL string literal needs, so a
      # catalog lookup built by interpolating the prefix into a quoted
      # literal is malformed for exactly this name.
      prefix = "ten'ant"

      on_exit(fn -> SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "ten'ant" CASCADE), []) end)

      migrate(Arcana.Migration, prefix: prefix)

      assert Arcana.Migration.recorded_version(Repo, prefix: prefix) ==
               Arcana.Migration.current_version()

      %{rows: [[rule]]} =
        SQL.query!(
          Repo,
          "SELECT con.confdeltype FROM pg_constraint con " <>
            "JOIN pg_class t ON t.oid = con.conrelid " <>
            "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
            "WHERE t.relname = 'arcana_documents' AND n.nspname = $1 " <>
            "AND con.contype = 'f'",
          [prefix]
        )

      assert rule == "r", "the FK convergence has to reach a quote-bearing schema too"
    end

    test "a dimension mismatch is caught in a schema whose name contains a dot" do
      # The verifier used to rebuild the prefix by splitting the qualified
      # name on ".", so a dotted schema resolved to the wrong one and a
      # contradicting dimension slipped through.
      prefix = "ten.ant"
      on_exit(fn -> SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "ten.ant" CASCADE), []) end)

      migrate(Arcana.Migration, dimensions: 384, prefix: prefix)

      %{rows: [[declared]]} =
        SQL.query!(
          Repo,
          "SELECT format_type(a.atttypid, a.atttypmod) FROM pg_attribute a " <>
            "JOIN pg_class c ON c.oid = a.attrelid " <>
            "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
            "WHERE c.relname = 'arcana_chunks' AND a.attname = 'embedding' " <>
            "AND a.attnum > 0 AND n.nspname = $1",
          [prefix]
        )

      assert declared == "vector(384)"

      err =
        assert_raise ArgumentError, fn ->
          migrate(Arcana.Migration, dimensions: 1024, prefix: prefix)
        end

      assert err.message =~ "already vector(384)",
             "the dotted schema was not inspected, so the mismatch was missed"
    end

    test "the graph stream honors the prefix too" do
      SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "tenant_b" CASCADE), [])
      on_exit(fn -> SQL.query!(Repo, ~s(DROP SCHEMA IF EXISTS "tenant_b" CASCADE), []) end)

      migrate(Arcana.Migration, prefix: "tenant_b")
      migrate(Arcana.Graph.Migration, prefix: "tenant_b")

      assert Arcana.Graph.Migration.recorded_version(Repo, prefix: "tenant_b") == 1
      assert Arcana.Graph.Migration.recorded_version(Repo) == 0

      # The raw SQL in converge_v1 has to be qualified as well, or it edits
      # whatever table the search_path happens to resolve to.
      %{rows: [[count]]} =
        SQL.query!(
          Repo,
          "SELECT count(*) FROM information_schema.columns " <>
            "WHERE table_schema = 'tenant_b' AND table_name = 'arcana_graph_communities' " <>
            "AND column_name = 'summary_fingerprint'",
          []
        )

      assert count == 1
    end
  end

  describe "Arcana.Graph.Migration" do
    setup do
      migrate(Arcana.Migration)
      :ok
    end

    test "creates the graph schema and records its own version" do
      migrate(Arcana.Graph.Migration)

      for table <- ~w(arcana_graph_entities arcana_graph_relationships
                      arcana_graph_entity_mentions arcana_graph_communities) do
        assert table_exists?(table), "#{table} was not created"
      end

      assert Arcana.Graph.Migration.recorded_version(Repo) ==
               Arcana.Graph.Migration.current_version()

      # Independent streams: installing the graph must not move the core one.
      assert Arcana.Migration.recorded_version(Repo) == Arcana.Migration.current_version()
    end

    test "includes what used to be separate upgrade migrations" do
      migrate(Arcana.Graph.Migration)

      assert "summary_fingerprint" in columns("arcana_graph_communities")

      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT indexname FROM pg_indexes WHERE tablename = 'arcana_graph_entity_mentions' " <>
            "AND schemaname = current_schema()",
          []
        )

      assert Enum.any?(List.flatten(rows), &String.contains?(&1, "entity_id_chunk_id")),
             "the entity mention unique index should come with v1"
    end

    test "converges a graph install that predates both upgrade migrations" do
      migrate(Arcana.Graph.Migration)

      # Roll back to the pre-upgrade shape, duplicates and all.
      SQL.query!(
        Repo,
        "DROP INDEX arcana_graph_entity_mentions_entity_id_chunk_id_index",
        []
      )

      SQL.query!(
        Repo,
        "ALTER TABLE arcana_graph_communities DROP COLUMN summary_fingerprint",
        []
      )

      SQL.query!(Repo, "COMMENT ON TABLE arcana_graph_entities IS NULL", [])
      assert Arcana.Graph.Migration.recorded_version(Repo) == 0

      migrate(Arcana.Graph.Migration)

      assert "summary_fingerprint" in columns("arcana_graph_communities")
      assert Arcana.Graph.Migration.recorded_version(Repo) == 1
    end

    test "adoption dedups mentions before converging their unique index" do
      # An install that never ran the standalone mentions upgrade has the
      # table, no unique index, and the duplicate pairs converge_v1's DELETE
      # exists to purge. Converging the index from the top of up/1 ran that
      # check before the DELETE, so adoption refused instead of cleaning up.
      migrate(Arcana.Graph.Migration)

      SQL.query!(Repo, "DROP INDEX arcana_graph_entity_mentions_entity_id_chunk_id_index", [])
      SQL.query!(Repo, "COMMENT ON TABLE arcana_graph_entities IS NULL", [])
      seed_duplicate_mentions()

      assert :ok = migrate(Arcana.Graph.Migration)

      assert unique_index?("arcana_graph_entity_mentions_entity_id_chunk_id_index"),
             "the mentions index should exist and be unique after adoption"

      assert mention_contexts() == ["older"],
             "the dedup should keep exactly the oldest row of each pair"
    end

    test "adoption rebuilds a wrong-shaped mentions index over duplicates" do
      # Same adoption, except the legacy template left a non-unique index under
      # the name Ecto generates, so create_if_not_exists skips it and only the
      # shape check can repair it - after the dedup, not before.
      migrate(Arcana.Graph.Migration)

      SQL.query!(Repo, "DROP INDEX arcana_graph_entity_mentions_entity_id_chunk_id_index", [])

      SQL.query!(
        Repo,
        "CREATE INDEX arcana_graph_entity_mentions_entity_id_chunk_id_index " <>
          "ON arcana_graph_entity_mentions (entity_id, chunk_id)",
        []
      )

      SQL.query!(Repo, "COMMENT ON TABLE arcana_graph_entities IS NULL", [])
      seed_duplicate_mentions()

      assert :ok = migrate(Arcana.Graph.Migration)

      assert unique_index?("arcana_graph_entity_mentions_entity_id_chunk_id_index"),
             "a non-unique index sharing the name was left in place"

      assert mention_contexts() == ["older"]
    end
  end
end
