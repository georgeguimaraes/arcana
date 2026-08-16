defmodule Arcana.Migration do
  @moduledoc """
  Versioned migrations for Arcana's core tables.

  Host applications run one migration and never write Arcana's DDL by hand:

      defmodule MyApp.Repo.Migrations.AddArcana do
        use Ecto.Migration

        def up, do: Arcana.Migration.up()
        def down, do: Arcana.Migration.down()
      end

  Later upgrades need no new migration content, only a new migration that
  calls `up/1` again. Each release adds version steps; `up/1` applies every
  step between the version recorded in your database and the target.

  ## Options

    * `:version` - target version (defaults to the latest)
    * `:dimensions` - embedding dimensions for `arcana_chunks.embedding`
      (defaults to 384). Must match `Arcana.Embedder.dimensions/1` for the
      embedder you run, or storing a chunk fails
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

  ## Version history

    * 1 - collections, documents, chunks and the evaluation tables

  """

  use Ecto.Migration

  @current_version 1
  @default_dimensions 384

  # The version lives in a comment on arcana_documents. It needs no table of
  # its own and survives anything that keeps the schema.
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

    if current > target do
      for version <- current..(target + 1)//-1, do: change(version, :down, opts)
      record_version(target, prefix)
    end

    :ok
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

  defp parse_version(comment) do
    case Regex.run(~r/arcana:(\d+)/, comment) do
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
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)
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
        # :restrict, not :nilify_all. The installer template said otherwise,
        # but every migrated database has :restrict and the dashboard relies
        # on a delete failing rather than silently orphaning documents.
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

  # Columns added by Arcana releases after the table itself shipped. An
  # existing install skips the create above, so these have to be applied on
  # their own or the schema reads a column the database lacks.
  defp converge_v1(prefix) do
    execute(
      "ALTER TABLE #{qualify("arcana_evaluation_test_cases", prefix)} " <>
        "ADD COLUMN IF NOT EXISTS reference_answer text"
    )
  end
end
