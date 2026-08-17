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
      Must match `Arcana.Embedder.dimensions/1` for the embedder you run
    * `:prefix` - Postgres schema to install into (defaults to the
      connection's current schema)
    * `:create_schema` - whether to create `:prefix` when it is missing
      (defaults to `true`, ignored without a prefix)

  ## Adoption

  Installs predating this module have graph tables but no recorded version.
  Version 1 converges them: it creates only what is absent and adds only the
  columns and indexes a later release introduced. It never drops anything.

  ## Where the version is recorded

  The applied version is stored as the Postgres comment on `arcana_graph_entities`, as
  exactly `arcana_graph:<n>`:

      SELECT obj_description('arcana_graph_entities'::regclass);

  Arcana owns that comment. Two consequences worth knowing before you point
  schema-documentation or data-catalog tooling at this table:

    * recording a version replaces whatever comment is there, so a
      description you wrote on `arcana_graph_entities` is lost on the next migration
    * a comment Arcana doesn't recognise reads as version 0, the same as a
      fresh install, so `up/1` re-runs the converge path (idempotent, and
      harmless) while `down/1` declines to drop anything

  Comment on any other table freely. Only `arcana_graph_entities` is reserved.

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
  Migrates down to `:version`, or removes the graph tables entirely.
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
  The latest graph version this release of Arcana knows how to migrate to.
  """
  def current_version, do: @current_version

  @doc """
  The graph version recorded in the database, or 0 when GraphRAG has never
  been installed.

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
  # contain "arcana_graph:2", and a bare integer (what Oban stores) would read a
  # host's own "1" as version 1. Anything we don't recognise reads as 0,
  # which is the same answer as "never installed" - see the moduledoc.
  defp parse_version(comment) do
    case Regex.run(~r/\Aarcana_graph:(\d+)\z/, String.trim(comment)) do
      [_, version] -> String.to_integer(version)
      _ -> 0
    end
  end

  defp record_version(0, _prefix), do: :ok

  defp record_version(version, prefix) do
    execute("COMMENT ON TABLE #{qualify(@version_table, prefix)} IS 'arcana_graph:#{version}'")
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
            "graph version #{target} is newer than this release of Arcana knows about " <>
              "(latest is #{@current_version}). Upgrade the arcana dependency first."
    end

    :ok
  end

  defp validate_target!(other) do
    raise ArgumentError, "version must be a positive integer, got: #{inspect(other)}"
  end

  defp validate_recorded!(current) when current > @current_version do
    raise ArgumentError,
          "this database is at graph version #{current}, which this release of Arcana does not " <>
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

  defp change(1, :up, opts) do
    dimensions = Keyword.get(opts, :dimensions, @default_dimensions)
    prefix = Keyword.get(opts, :prefix)

    execute("CREATE EXTENSION IF NOT EXISTS vector")

    create_if_not_exists table(:arcana_graph_entities, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:type, :string, null: false)
      add(:description, :text)
      add(:embedding, :vector, size: dimensions)
      add(:metadata, :map, default: %{})

      add(
        :chunk_id,
        references(:arcana_chunks, type: :binary_id, on_delete: :nilify_all, prefix: prefix)
      )

      add(
        :collection_id,
        references(:arcana_collections, type: :binary_id, on_delete: :delete_all, prefix: prefix)
      )

      timestamps()
    end

    create_if_not_exists(
      unique_index(:arcana_graph_entities, [:name, :collection_id], prefix: prefix)
    )

    create_if_not_exists(index(:arcana_graph_entities, [:chunk_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_entities, [:collection_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_entities, [:type], prefix: prefix))

    execute("""
    CREATE INDEX IF NOT EXISTS arcana_graph_entities_embedding_idx
    ON #{qualify("arcana_graph_entities", prefix)}
    USING hnsw (embedding vector_cosine_ops)
    WHERE embedding IS NOT NULL
    """)

    create_if_not_exists table(:arcana_graph_entity_mentions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:span_start, :integer)
      add(:span_end, :integer)
      add(:context, :text)

      add(
        :entity_id,
        references(:arcana_graph_entities,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :chunk_id,
        references(:arcana_chunks, type: :binary_id, on_delete: :delete_all, prefix: prefix),
        null: false
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_entity_mentions, [:entity_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_entity_mentions, [:chunk_id], prefix: prefix))

    create_if_not_exists table(:arcana_graph_relationships, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string, null: false)
      add(:description, :text)
      add(:strength, :integer)
      add(:metadata, :map, default: %{})

      add(
        :source_id,
        references(:arcana_graph_entities,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(
        :target_id,
        references(:arcana_graph_entities,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_relationships, [:source_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_relationships, [:target_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_relationships, [:type], prefix: prefix))

    create_if_not_exists table(:arcana_graph_communities, primary_key: false, prefix: prefix) do
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
        references(:arcana_collections, type: :binary_id, on_delete: :delete_all, prefix: prefix)
      )

      timestamps()
    end

    create_if_not_exists(index(:arcana_graph_communities, [:collection_id], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_communities, [:level], prefix: prefix))
    create_if_not_exists(index(:arcana_graph_communities, [:dirty], prefix: prefix))

    # mark_overlapping_communities_dirty/3 filters with `entity_ids && ...`,
    # which scans every community without this.
    execute("""
    CREATE INDEX IF NOT EXISTS arcana_graph_communities_entity_ids_idx
    ON #{qualify("arcana_graph_communities", prefix)}
    USING gin (entity_ids)
    """)

    converge_v1(prefix)
  end

  defp change(1, :down, opts) do
    prefix = Keyword.get(opts, :prefix)

    drop_if_exists(table(:arcana_graph_communities, prefix: prefix))
    drop_if_exists(table(:arcana_graph_entity_mentions, prefix: prefix))
    drop_if_exists(table(:arcana_graph_relationships, prefix: prefix))
    drop_if_exists(table(:arcana_graph_entities, prefix: prefix))
  end

  # Everything a release added after the tables first shipped. An install
  # that already has the tables skips the creates above, so these run on
  # their own. Both were standalone upgrade tasks before this module.
  defp converge_v1(prefix) do
    execute(
      "ALTER TABLE #{qualify("arcana_graph_communities", prefix)} " <>
        "ADD COLUMN IF NOT EXISTS summary_fingerprint varchar(255)"
    )

    # Duplicates have to go before the unique index can exist. Keep the
    # oldest row per pair: ctid is a physical location, not insertion order,
    # so it only breaks ties within the same timestamp.
    execute("""
    DELETE FROM #{qualify("arcana_graph_entity_mentions", prefix)} m
    USING #{qualify("arcana_graph_entity_mentions", prefix)} kept
    WHERE m.entity_id = kept.entity_id
      AND m.chunk_id = kept.chunk_id
      AND (m.inserted_at > kept.inserted_at
           OR (m.inserted_at = kept.inserted_at AND m.ctid > kept.ctid))
    """)

    create_if_not_exists(
      unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id], prefix: prefix)
    )
  end
end
