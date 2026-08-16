defmodule Arcana.Graph.Migration do
  @moduledoc """
  Versioned migrations for Arcana's GraphRAG tables.

  GraphRAG is optional, so it carries its own version separate from
  `Arcana.Migration`. Install it the same way:

      defmodule MyApp.Repo.Migrations.AddArcanaGraph do
        use Ecto.Migration

        def up, do: Arcana.Graph.Migration.up(dimensions: 384)
        def down, do: Arcana.Graph.Migration.down()
      end

  Upgrading needs no new DDL, only another migration calling `up/1`.

  ## Options

    * `:version` - target version (defaults to the latest)
    * `:dimensions` - embedding dimensions for `arcana_graph_entities.embedding`.
      Must match `Arcana.Embedder.dimensions/1` for the embedder you run.

  ## Adoption

  Installs predating this module have graph tables but no recorded version.
  Version 1 converges them: it creates only what is absent and adds only the
  columns and indexes a later release introduced. It never drops anything.

  ## Version history

    * 1 - entities, relationships, mentions and communities, including the
      entity-mention unique index and `communities.summary_fingerprint` that
      earlier releases shipped as separate upgrade migrations

  """

  use Ecto.Migration

  @current_version 1
  @default_dimensions 384

  @version_table "arcana_graph_entities"

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
  Migrates down to `:version`, or removes the graph tables entirely.
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
  The latest graph version this release of Arcana knows how to migrate to.
  """
  def current_version, do: @current_version

  @doc """
  The graph version recorded in the database, or 0 when GraphRAG has never
  been installed.

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
    _ -> 0
  end

  defp parse_version(nil), do: 0

  defp parse_version(comment) do
    case Regex.run(~r/arcana_graph:(\d+)/, comment) do
      [_, version] -> String.to_integer(version)
      _ -> 0
    end
  end

  defp record_version(0), do: :ok

  defp record_version(version) do
    execute("COMMENT ON TABLE #{@version_table} IS 'arcana_graph:#{version}'")
  end

  defp validate_target!(target) when is_integer(target) and target >= 1 do
    if target > @current_version do
      raise ArgumentError,
            "graph version #{target} is newer than this release of Arcana knows about " <>
              "(latest is #{@current_version}). Upgrade the arcana dependency first."
    end

    :ok
  end

  defp validate_target!(other) do
    raise ArgumentError, "version must be a positive integer, got: #{inspect(other)}"
  end

  # === Version 1 ===

  defp change(1, :up, opts) do
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)

    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create_if_not_exists table(:arcana_graph_entities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:type, :string, null: false)
      add(:description, :text)
      add(:embedding, :vector, size: dimensions)
      add(:metadata, :map, default: %{})
      add(:chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :nilify_all))

      add(
        :collection_id,
        references(:arcana_collections, type: :binary_id, on_delete: :delete_all)
      )

      timestamps()
    end

    create_if_not_exists(unique_index(:arcana_graph_entities, [:name, :collection_id]))
    create_if_not_exists(index(:arcana_graph_entities, [:collection_id]))
    create_if_not_exists(index(:arcana_graph_entities, [:type]))

    execute("""
    CREATE INDEX IF NOT EXISTS arcana_graph_entities_embedding_idx ON arcana_graph_entities
    USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL
    """)

    create_if_not_exists table(:arcana_graph_entity_mentions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:span_start, :integer)
      add(:span_end, :integer)
      add(:context, :text)

      add(
        :entity_id,
        references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_entity_mentions, [:entity_id]))
    create_if_not_exists(index(:arcana_graph_entity_mentions, [:chunk_id]))

    create_if_not_exists table(:arcana_graph_relationships, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string, null: false)
      add(:description, :text)
      add(:strength, :integer)
      add(:metadata, :map, default: %{})

      add(
        :source_id,
        references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :target_id,
        references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_relationships, [:source_id]))
    create_if_not_exists(index(:arcana_graph_relationships, [:target_id]))
    create_if_not_exists(index(:arcana_graph_relationships, [:type]))

    create_if_not_exists table(:arcana_graph_communities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:level, :integer, null: false)
      add(:description, :text)
      add(:summary, :text)
      add(:entity_ids, {:array, :binary_id}, default: [])
      add(:dirty, :boolean, default: true)
      add(:change_count, :integer, default: 0)
      add(:summary_fingerprint, :string)

      add(
        :collection_id,
        references(:arcana_collections, type: :binary_id, on_delete: :delete_all)
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_communities, [:collection_id]))
    create_if_not_exists(index(:arcana_graph_communities, [:level]))

    converge_v1()
  end

  defp change(1, :down, _opts) do
    drop_if_exists(table(:arcana_graph_communities))
    drop_if_exists(table(:arcana_graph_entity_mentions))
    drop_if_exists(table(:arcana_graph_relationships))
    drop_if_exists(table(:arcana_graph_entities))
  end

  # Everything a release added after the tables first shipped. An install
  # that already has the tables skips the creates above, so these run on
  # their own. Both were standalone upgrade tasks before this module.
  defp converge_v1 do
    execute(
      "ALTER TABLE arcana_graph_communities ADD COLUMN IF NOT EXISTS summary_fingerprint varchar(255)"
    )

    # Duplicates have to go before the unique index can exist. Keep the
    # oldest row per pair: ctid is a physical location, not insertion order,
    # so it only breaks ties within the same timestamp.
    execute("""
    DELETE FROM arcana_graph_entity_mentions m
    USING arcana_graph_entity_mentions kept
    WHERE m.entity_id = kept.entity_id
      AND m.chunk_id = kept.chunk_id
      AND (m.inserted_at > kept.inserted_at
           OR (m.inserted_at = kept.inserted_at AND m.ctid > kept.ctid))
    """)

    create_if_not_exists(unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id]))
  end
end
