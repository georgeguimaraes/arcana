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
      (defaults to #{384}). Must match `Arcana.Embedder.dimensions/1` for the
      embedder you run, or storing a chunk fails.

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

    current = recorded_version(repo())

    if current < target do
      for version <- (current + 1)..target//1, do: change(version, :up, opts)
      record_version(target)
    end

    :ok
  end

  @doc """
  Migrates down to `:version`, or removes Arcana's tables entirely.

  Defaults to version 0, which drops everything this module created.
  """
  def down(opts \\ []) do
    target = Keyword.get(opts, :version, 0)
    current = recorded_version(repo())

    if current > target do
      for version <- current..(target + 1)//-1, do: change(version, :down, opts)
      record_version(target)
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
  to the migration's own repo.
  """
  def recorded_version(repo \\ nil) do
    repo = repo || repo()

    %{rows: [[comment]]} =
      repo.query!(
        "SELECT obj_description(c.oid) FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND n.nspname = current_schema()",
        [@version_table]
      )

    parse_version(comment)
  rescue
    # No table, no version: this is a fresh install.
    _ -> 0
  end

  defp parse_version(nil), do: 0

  defp parse_version(comment) do
    case Regex.run(~r/arcana:(\d+)/, comment) do
      [_, version] -> String.to_integer(version)
      _ -> 0
    end
  end

  defp record_version(0) do
    # Everything is gone, so there is nothing left to comment on.
    :ok
  end

  defp record_version(version) do
    execute("COMMENT ON TABLE #{@version_table} IS 'arcana:#{version}'")
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

  # === Version 1 ===
  #
  # Written to be safe against a database that already has some or all of
  # this, because installs predating this module adopt it by running v1.

  defp change(1, :up, opts) do
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)

    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create_if_not_exists table(:arcana_collections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:description, :text)

      timestamps()
    end

    create_if_not_exists(unique_index(:arcana_collections, [:name]))

    create_if_not_exists table(:arcana_documents, primary_key: false) do
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
        references(:arcana_collections, type: :binary_id, on_delete: :nilify_all)
      )

      timestamps()
    end

    create_if_not_exists table(:arcana_chunks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:text, :text, null: false)
      add(:embedding, :vector, size: dimensions, null: false)
      add(:chunk_index, :integer, default: 0)
      add(:token_count, :integer)
      add(:metadata, :map, default: %{})
      add(:document_id, references(:arcana_documents, type: :binary_id, on_delete: :delete_all))

      timestamps()
    end

    create_if_not_exists(index(:arcana_chunks, [:document_id]))
    create_if_not_exists(index(:arcana_documents, [:source_id]))
    create_if_not_exists(index(:arcana_documents, [:collection_id]))

    execute("""
    CREATE INDEX IF NOT EXISTS arcana_chunks_embedding_idx ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    """)

    create_if_not_exists table(:arcana_evaluation_test_cases, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:question, :text, null: false)
      add(:source, :string, null: false, default: "synthetic")
      add(:reference_answer, :text)
      add(:source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create_if_not_exists table(:arcana_evaluation_test_case_chunks, primary_key: false) do
      add(
        :test_case_id,
        references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false)
    end

    create_if_not_exists(
      unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id])
    )

    create_if_not_exists table(:arcana_evaluation_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:status, :string, null: false, default: "running")
      add(:metrics, :map, default: %{})
      add(:results, :map, default: %{})
      add(:config, :map, default: %{})
      add(:test_case_count, :integer, default: 0)

      timestamps()
    end

    create_if_not_exists(index(:arcana_evaluation_runs, [:inserted_at]))

    # Columns added by Arcana releases after the table itself shipped. An
    # existing install skips the create above, so these have to be applied
    # on their own or the schema reads a column the database lacks.
    execute(
      "ALTER TABLE arcana_evaluation_test_cases ADD COLUMN IF NOT EXISTS reference_answer text"
    )
  end

  defp change(1, :down, _opts) do
    drop_if_exists(table(:arcana_evaluation_runs))
    drop_if_exists(table(:arcana_evaluation_test_case_chunks))
    drop_if_exists(table(:arcana_evaluation_test_cases))
    drop_if_exists(table(:arcana_chunks))
    drop_if_exists(table(:arcana_documents))
    drop_if_exists(table(:arcana_collections))
    # The vector extension stays: other tables in the database may use it.
  end
end
