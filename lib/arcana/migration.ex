defmodule Arcana.Migration do
  @moduledoc """
  Versioned migrations for Arcana's core tables.

  Host applications run one migration and never write Arcana's DDL by hand:

      defmodule MyApp.Repo.Migrations.AddArcana do
        use Ecto.Migration

        def up, do: Arcana.Migration.up(dimensions: 384)
        def down, do: Arcana.Migration.down()
      end

  Later upgrades need no new migration content, only a new migration that
  calls `up/1` again. Each release adds version steps; `up/1` applies every
  step between the version recorded in your database and the target.

  ## Options

    * `:version` - target version (defaults to the latest)
    * `:dimensions` - **required.** Embedding dimensions for
      `arcana_chunks.embedding`. Must match `Arcana.Embedder.dimensions/1`
      for the embedder you run, or storing a chunk fails. There is no
      default: the column can't be resized without rebuilding every vector
      in it, and a wrong guess stays invisible on a database that already
      has the table. `mix arcana.install` detects it from your configured embedder and writes
      it into the migration it generates
    * `:prefix` - Postgres schema to install into (defaults to the
      connection's current schema)
    * `:create_schema` - whether to create `:prefix` when it is missing
      (defaults to `true`, ignored without a prefix)

  ## Adoption

  Installs created before this module existed have tables but no recorded
  version. Version 1 is written to converge them: tables are created only
  when absent, and columns added by later Arcana releases are added only
  when missing. Running it against an existing database changes nothing it
  already has, and never drops anything.

  ## Where the version is recorded

  The applied version is stored as the Postgres comment on `arcana_documents`, as
  exactly `arcana:<n>`:

      SELECT obj_description('arcana_documents'::regclass);

  Arcana owns that comment. Two consequences worth knowing before you point
  schema-documentation or data-catalog tooling at this table:

    * recording a version replaces whatever comment is there, so a
      description you wrote on `arcana_documents` is lost on the next migration
    * a comment Arcana doesn't recognise reads as version 0, the same as a
      fresh install, so `up/1` re-runs the converge path (idempotent, and
      harmless) while `down/1` declines to drop anything

  Comment on any other table freely. Only `arcana_documents` is reserved.

  ## Version history

    * 1 - collections, documents, chunks and the evaluation tables

  """

  use Ecto.Migration

  alias Arcana.Migration.Dimensions

  @current_version 1

  @version_table "arcana_documents"

  @doc """
  Migrates up to `:version`, or to the latest version.
  """
  def up(opts \\ []) do
    target = Keyword.get(opts, :version, @current_version)
    validate_target!(target)

    prefix = Keyword.get(opts, :prefix)
    current = recorded_version(repo(), prefix: prefix)
    validate_recorded!(current)

    # Before the version comparison, so a wrong number is caught even when
    # this database is already at the target and there is nothing to apply.
    verify_embedding_dimensions!(require_dimensions!(opts), prefix)

    if current < target do
      maybe_create_schema(prefix, opts)
      for version <- (current + 1)..target//1, do: change(version, :up, opts)
      record_version(target, prefix)
    end

    :ok
  end

  @doc """
  Migrates down to `:version`, or removes Arcana's tables entirely.

  Defaults to version 0, which drops everything this module created.
  """
  def down(opts \\ []) do
    target = Keyword.get(opts, :version, 0)
    validate_rollback_target!(target)

    prefix = Keyword.get(opts, :prefix)
    current = recorded_version(repo(), prefix: prefix)
    validate_recorded!(current)

    if current == 0, do: refuse_blind_rollback!(prefix)

    if current > target do
      for version <- current..(target + 1)//-1, do: change(version, :down, opts)
      record_version(target, prefix)
    end

    :ok
  end

  # Version 0 means "no marker found", which covers two different states:
  # nothing is installed, or the tables are there and the marker isn't -
  # either clobbered by a host comment, or never written because the install
  # predates versioning. Any table this module owns still being present
  # tells them apart - not just the version table, which can be the one
  # that's missing while its siblings remain.
  #
  # Only the first is safe to answer by doing nothing. In the others the
  # operator asked to remove tables that are really there, and silently
  # dropping nothing is the failure this module's own rescue clause goes out
  # of its way to avoid.
  defp refuse_blind_rollback!(prefix) do
    case owned_tables_present(prefix) do
      [] ->
        # Genuinely nothing here, which is the one case 0 can be answered
        # by doing nothing.
        :ok

      present ->
        raise blind_rollback_message(present, prefix)
    end
  end

  defp blind_rollback_message(present, prefix) do
    listed = present |> Enum.sort() |> Enum.map_join("\n", &"        #{&1}")

    recovery =
      if @version_table in present do
        """
        Record the version that is actually applied and run the rollback again:

            COMMENT ON TABLE #{qualify(@version_table, prefix)} IS 'arcana:<n>';
        """
      else
        """
        #{qualify(@version_table, prefix)} is not among them, so there is nowhere
        to record a version. This install is partial: drop what is left by hand,
        or restore that table and record its version, then retry.
        """
      end

    """
    Arcana.Migration.down/1 can't tell which version is applied.

    These tables are present, so something is installed here, but no
    recognised version marker was found:

    #{listed}

    Either a host comment replaced the marker, this install predates
    versioned migrations, or the schema was modified by hand. Rolling back
    blind could drop tables this release never created, so nothing was
    changed.

    #{recovery}
    See "Where the version is recorded" in Arcana.Migration for how this is stored.
    """
  end

  # The tables change(1, :down, _) drops. Any of them being present means a
  # rollback has something to do, so the version table alone is not enough
  # evidence: it can be gone while its siblings remain.
  #
  # relkind is constrained to ordinary and partitioned tables, so a view or
  # sequence that happens to share a name is not mistaken for an install.
  defp owned_tables_present(prefix) do
    %{rows: rows} =
      repo().query!(
        "SELECT c.relname FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = ANY($1) AND c.relkind IN ('r', 'p') " <>
          "AND n.nspname = COALESCE($2, current_schema())",
        [
          ~w(
                   arcana_collections
                   arcana_documents
                   arcana_chunks
                   arcana_evaluation_test_cases
                   arcana_evaluation_test_case_chunks
                   arcana_evaluation_runs
          ),
          prefix
        ]
      )

    List.flatten(rows)
  end

  @doc """
  The latest version this release of Arcana knows how to migrate to.
  """
  def current_version, do: @current_version

  @doc """
  The version recorded in the database, or 0 when Arcana has never been
  installed.

  Pass a repo when calling this outside a migration; inside one it defaults
  to the migration's own repo. Pass `:prefix` to read a version recorded in
  a Postgres schema other than the current one.

  Both arguments default, so options must be given with a repo:
  `recorded_version(MyApp.Repo, prefix: "tenant_a")`. A lone keyword list
  would bind to the repo argument.
  """
  def recorded_version(repo \\ nil, opts \\ []) do
    repo = repo || repo()
    prefix = Keyword.get(opts, :prefix)

    %{rows: [[comment]]} =
      repo.query!(
        "SELECT obj_description(c.oid) FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND n.nspname = COALESCE($2, current_schema())",
        [@version_table, prefix]
      )

    parse_version(comment)
  rescue
    # The table isn't there, which is what "never installed" looks like.
    # Anything else - a bad connection, missing privileges - has to
    # propagate, or down/1 would quietly decline to drop anything.
    error in [Postgrex.Error] ->
      if error.postgres[:code] in [:undefined_table, :invalid_schema_name],
        do: 0,
        else: reraise(error, __STACKTRACE__)

    _ in [MatchError, DBConnection.EncodeError] ->
      0
  end

  defp parse_version(nil), do: 0

  # Anchored, so only a comment that is exactly the marker counts. An
  # unanchored match read a version out of any prose that happened to
  # contain "arcana:2", and a bare integer (what Oban stores) would read a
  # host's own "1" as version 1. Anything we don't recognise reads as 0,
  # which is the same answer as "never installed" - see the moduledoc.
  defp parse_version(comment) do
    case Regex.run(~r/\Aarcana:(\d+)\z/, String.trim(comment)) do
      [_, version] -> String.to_integer(version)
      _ -> 0
    end
  end

  # Everything is gone, so there is nothing left to comment on.
  defp record_version(0, _prefix), do: :ok

  defp record_version(version, prefix) do
    execute("COMMENT ON TABLE #{qualify(@version_table, prefix)} IS 'arcana:#{version}'")
  end

  # Raw SQL gets none of Ecto's prefix handling, so anything that doesn't go
  # through table/2 or index/3 has to be qualified by hand.
  defp qualify(name, nil), do: quoted(name)
  defp qualify(name, prefix), do: quoted(prefix) <> "." <> quoted(name)

  # A double quote inside an identifier is escaped by doubling it. Prefixes
  # can come from runtime config, so this is not only about odd names.
  defp quoted(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")

  defp maybe_create_schema(nil, _opts), do: :ok

  defp maybe_create_schema(prefix, opts) do
    if Keyword.get(opts, :create_schema, true) do
      execute("CREATE SCHEMA IF NOT EXISTS #{quoted(prefix)}")
    end

    :ok
  end

  defp verify_embedding_dimensions!(requested, prefix) do
    execute(fn ->
      Dimensions.verify!(
        repo(),
        requested,
        Arcana.Migration,
        "arcana_chunks",
        prefix,
        """
        resize the column deliberately with
        `mix arcana.gen.embedding_migration` and re-embed.
        """
      )
    end)
  end

  defp require_dimensions!(opts) do
    Dimensions.require!(opts, Arcana.Migration, "arcana_chunks")
  end

  defp validate_target!(target) when is_integer(target) and target >= 1 do
    if target > @current_version do
      raise ArgumentError,
            "version #{target} is newer than this release of Arcana knows about " <>
              "(latest is #{@current_version}). Upgrade the arcana dependency first."
    end

    :ok
  end

  defp validate_target!(other) do
    raise ArgumentError, "version must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_recorded!(current) when current > @current_version do
    raise ArgumentError,
          "this database is at version #{current}, which this release of Arcana does not " <>
            "know about (latest is #{@current_version}). Upgrade the arcana dependency."
  end

  defp validate_recorded!(_current), do: :ok

  defp validate_rollback_target!(target)
       when is_integer(target) and target >= 0 and target <= @current_version,
       do: :ok

  defp validate_rollback_target!(other) do
    raise ArgumentError,
          "rollback target must be between 0 and #{@current_version}, got: #{inspect(other)}"
  end

  # === Version 1 ===
  #
  # Written to be safe against a database that already has some or all of
  # this, because installs predating this module adopt it by running v1.

  defp change(1, :up, opts) do
    dimensions = require_dimensions!(opts)
    prefix = Keyword.get(opts, :prefix)

    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create_if_not_exists table(:arcana_collections, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)

      timestamps()
    end

    create_if_not_exists(unique_index(:arcana_collections, [:name], prefix: prefix))

    create_if_not_exists table(:arcana_documents, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:content, :text)
      add(:content_type, :string, default: "text/plain")
      add(:source_id, :string)
      add(:file_path, :string)
      add(:metadata, :map, default: %{})
      add(:status, :string, default: "pending")
      add(:error, :text)
      add(:chunk_count, :integer, default: 0)

      add(
        :collection_id,
        # :restrict so deleting a collection that still has documents fails
        # loudly. Every database installed before this module has
        # :nilify_all instead - see converge_v1/1, which swaps it.
        references(:arcana_collections,
          type: :binary_id,
          on_delete: :restrict,
          prefix: prefix
        )
      )

      timestamps()
    end

    create_if_not_exists table(:arcana_chunks, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:text, :text, null: false)
      add(:embedding, :vector, size: dimensions, null: false)
      add(:chunk_index, :integer, default: 0)
      add(:token_count, :integer)
      add(:metadata, :map, default: %{})

      add(
        :document_id,
        references(:arcana_documents, type: :binary_id, on_delete: :delete_all, prefix: prefix)
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_chunks, [:document_id], prefix: prefix))
    create_if_not_exists(index(:arcana_documents, [:source_id], prefix: prefix))
    create_if_not_exists(index(:arcana_documents, [:collection_id], prefix: prefix))

    execute("""
    CREATE INDEX IF NOT EXISTS arcana_chunks_embedding_idx
    ON #{qualify("arcana_chunks", prefix)}
    USING hnsw (embedding vector_cosine_ops)
    """)

    create_if_not_exists table(:arcana_evaluation_test_cases,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:question, :text, null: false)
      add(:source, :string, null: false, default: "synthetic")
      add(:reference_answer, :text)

      add(
        :source_chunk_id,
        references(:arcana_chunks, type: :uuid, on_delete: :nilify_all, prefix: prefix)
      )

      timestamps()
    end

    create_if_not_exists table(:arcana_evaluation_test_case_chunks,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(
        :test_case_id,
        references(:arcana_evaluation_test_cases,
          type: :uuid,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :chunk_id,
        references(:arcana_chunks, type: :uuid, on_delete: :delete_all, prefix: prefix),
        null: false
      )
    end

    create_if_not_exists(
      unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id],
        prefix: prefix
      )
    )

    create_if_not_exists table(:arcana_evaluation_runs, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:status, :string, null: false, default: "running")
      add(:metrics, :map, default: %{})
      add(:results, :map, default: %{})
      add(:config, :map, default: %{})
      add(:test_case_count, :integer, default: 0)

      timestamps()
    end

    create_if_not_exists(index(:arcana_evaluation_runs, [:inserted_at], prefix: prefix))

    converge_v1(prefix)
  end

  defp change(1, :down, opts) do
    prefix = Keyword.get(opts, :prefix)

    drop_if_exists(table(:arcana_evaluation_runs, prefix: prefix))
    drop_if_exists(table(:arcana_evaluation_test_case_chunks, prefix: prefix))
    drop_if_exists(table(:arcana_evaluation_test_cases, prefix: prefix))
    drop_if_exists(table(:arcana_chunks, prefix: prefix))
    drop_if_exists(table(:arcana_documents, prefix: prefix))
    drop_if_exists(table(:arcana_collections, prefix: prefix))
    # The vector extension stays: other tables in the database may use it.
  end

  # Columns and constraints added by Arcana releases after the table itself
  # shipped. An existing install skips the create above, so these have to be
  # applied on their own or the schema reads a column the database lacks.
  defp converge_v1(prefix) do
    execute(
      "ALTER TABLE #{qualify("arcana_evaluation_test_cases", prefix)} " <>
        "ADD COLUMN IF NOT EXISTS reference_answer text"
    )

    converge_collection_fk(prefix)
  end

  # Every installer template shipped before this module emitted
  # `on_delete: :nilify_all` on documents.collection_id, so deleting a
  # collection quietly detached its documents instead of refusing. They kept
  # their chunks and stayed searchable while belonging to nothing, and the
  # dashboard had no way to tell you it had happened.
  #
  # A fresh install gets :restrict from the create above. Without this an
  # adopted database keeps the old rule forever and the same delete behaves
  # differently depending on when the database was first installed.
  #
  # The name is Ecto's default for this reference and is what every template
  # produced; a hand-renamed constraint is left alone rather than guessed at.
  defp converge_collection_fk(prefix) do
    documents = qualify("arcana_documents", prefix)
    collections = qualify("arcana_collections", prefix)

    # The catalog lookup is parameterized rather than built by interpolating
    # the prefix into a quoted SQL literal: `qualify/2` escapes an
    # identifier, which is not the same escaping a string literal needs, and
    # a prefix carrying a quote would produce malformed SQL. Same join
    # `recorded_version/2` uses. Only the ALTERs interpolate, as identifiers.
    execute(fn ->
      %{rows: rows} =
        repo().query!(
          "SELECT con.confdeltype FROM pg_constraint con " <>
            "JOIN pg_class t ON t.oid = con.conrelid " <>
            "JOIN pg_namespace n ON n.oid = t.relnamespace " <>
            "WHERE con.conname = 'arcana_documents_collection_id_fkey' " <>
            "AND t.relname = 'arcana_documents' " <>
            "AND n.nspname = COALESCE($1, current_schema())",
          [prefix]
        )

      # 'r' is RESTRICT. Anything else is an old install to convert; no row
      # at all means a hand-renamed constraint, which is left alone rather
      # than guessed at.
      if match?([[rule]] when rule != ~c"r" and rule != "r", rows) do
        repo().query!(
          "ALTER TABLE #{documents} DROP CONSTRAINT arcana_documents_collection_id_fkey"
        )

        repo().query!(
          "ALTER TABLE #{documents} " <>
            "ADD CONSTRAINT arcana_documents_collection_id_fkey " <>
            "FOREIGN KEY (collection_id) REFERENCES #{collections}(id) ON DELETE RESTRICT"
        )
      end
    end)
  end
end
