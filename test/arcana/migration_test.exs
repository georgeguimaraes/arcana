defmodule Arcana.MigrationTest do
  @moduledoc """
  Runs the versioned migrations against a real database.

  Not async and not sandboxed: these run DDL and inspect the catalog, which
  a sandbox transaction would roll back out from under the assertions. Each
  test works in its own Postgres schema so they can't collide.
  """
  use ExUnit.Case, async: false

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

  defp migrate(module, opts \\ []), do: run(module, :up, opts)
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
  end
end
