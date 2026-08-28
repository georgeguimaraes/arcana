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

  Upgrade by adding another host migration that calls `up/1`. Version 2 adds
  relationship provenance DDL and clears legacy relationship facts that have
  no source chunk.

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
  columns and indexes a later release introduced. The one thing it drops is a
  unique index whose shape is wrong: see "What converge verifies" below.

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

  ## What converge verifies

  Adoption creates only what is absent, so most objects are checked by name
  alone. Three are verified against the catalog and corrected when they
  differ, because being merely present isn't enough:

    * `arcana_documents.collection_id`'s delete rule, since older templates
      emitted `ON DELETE SET NULL`
    * the embedding column's dimension, which is compared against
      `:dimensions` rather than altered
    * the unique indexes on `arcana_graph_entities(name, collection_id)` and `arcana_graph_entity_mentions(entity_id, chunk_id)`, since `create_if_not_exists` matches on the index name and an
      older template may have created one with a different shape

  Everything else is create-if-absent. For the plain indexes that is
  deliberate: a differing one costs performance, not correctness.

  ## Version history

    * 1 - entities, relationships, mentions and communities, including the
      entity-mention unique index and `communities.summary_fingerprint` that
      earlier releases shipped as separate upgrade migrations
    * 2 - canonical relationship facts with per-chunk evidence. Existing
      relationships are cleared because their source chunks cannot be inferred;
      rebuild the graph after upgrading

  ## Uninstall ownership

  Target version 0 removes only Arcana's graph tables and table-contained
  objects. It leaves the core tables, Postgres schema, and `vector` extension in
  place. Foreign keys, views, and materialized views owned by the host
  application block uninstall with their schema-qualified identities. Arcana
  never uses `DROP ... CASCADE`, because that would delete host-owned objects.

  """

  use Ecto.Migration

  alias Arcana.Migration.Dependencies
  alias Arcana.Migration.Dimensions
  alias Arcana.Migration.Registry
  alias Arcana.Migration.SchemaScope
  alias Arcana.Migration.UniqueIndex

  @current_version Registry.current_version(:graph)
  @version_table Registry.version_table(:graph)

  @doc """
  Migrates up to `:version`, or to the latest version.
  """
  def up(opts \\ []) do
    target = Keyword.get(opts, :version, @current_version)
    validate_target!(target)

    prefix = SchemaScope.resolve(repo(), :graph, Keyword.get(opts, :prefix))
    opts = Keyword.put(opts, :prefix, prefix)
    current = recorded_version(repo(), prefix: prefix)
    validate_recorded!(current)

    # Before the version comparison, so a wrong number is caught even when
    # this database is already at the target and there is nothing to apply.
    verify_embedding_dimensions!(require_dimensions!(opts), prefix)

    # Nothing purges duplicate entity names, so this preflight has to beat
    # change(1, :up, _)'s create_if_not_exists to explain them rather than let
    # Postgres raise a bare unique violation.
    converge_entities_index!(prefix)

    if current < target do
      maybe_create_schema(prefix, opts)
      for version <- (current + 1)..target//1, do: change(version, :up, opts)
    end

    # Mentions are the one exception, so this sits after the steps: converge_v1
    # purges the duplicate pairs a unique index cannot coexist with, and
    # checking first refused the migration over duplicates it was about to
    # clean. Still outside the version comparison, so an install already at the
    # target gets repaired too.
    converge_mentions_index!(prefix)

    if target >= 2 do
      converge_v2_indexes!(prefix)
      verify_v2_schema!(prefix)
    end

    if current < target, do: record_version(target, prefix)

    :ok
  end

  @doc """
  Migrates down to `:version`, or removes the graph tables entirely after
  checking for host-owned dependents.
  """
  def down(opts \\ []) do
    target = Keyword.get(opts, :version, 0)
    validate_rollback_target!(target)

    prefix = SchemaScope.resolve(repo(), :graph, Keyword.get(opts, :prefix))
    opts = Keyword.put(opts, :prefix, prefix)
    current = recorded_version(repo(), prefix: prefix)
    validate_recorded!(current)

    if current == 0, do: refuse_blind_rollback!(prefix)

    if current >= 2 and target == 1 do
      raise """
      Arcana graph migration v2 cannot be rolled back to v1 safely.

      Version 2 stores relationship provenance in arcana_graph_relationship_evidence.
      Dropping that table loses the information needed to reconstruct v2 on a later
      upgrade. Roll back to version 0 to uninstall all graph tables, or restore a
      pre-v2 database backup.
      """
    end

    if current > target and target == 0, do: preflight_uninstall!(prefix)

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

            COMMENT ON TABLE #{qualify(@version_table, prefix)} IS 'arcana_graph:<n>';
        """
      else
        """
        #{qualify(@version_table, prefix)} is not among them, so there is nowhere
        to record a version. This install is partial: drop what is left by hand,
        or restore that table and record its version, then retry.
        """
      end

    """
    Arcana.Graph.Migration.down/1 can't tell which version is applied.

    These tables are present, so something is installed here, but no
    recognised version marker was found:

    #{listed}

    Either a host comment replaced the marker, this install predates
    versioned migrations, or the schema was modified by hand. Rolling back
    blind could drop tables this release never created, so nothing was
    changed.

    #{recovery}
    See "Where the version is recorded" in Arcana.Graph.Migration for how this is stored.
    """
  end

  # The tables change(1, :down, _) drops. Any of them being present means a
  # rollback has something to do, so the version table alone is not enough
  # evidence: it can be gone while its siblings remain.
  #
  # relkind is constrained to ordinary and partitioned tables, so a view or
  # sequence that happens to share a name is not mistaken for an install.
  defp owned_tables_present(prefix), do: Registry.present(repo(), :graph, prefix)

  defp preflight_uninstall!(prefix) do
    execute(fn ->
      case Dependencies.external(repo(), :graph, prefix) do
        [] ->
          :ok

        dependents ->
          listed = Enum.map_join(dependents, "\n", &"    #{&1}")
          retry_scope = if prefix, do: "with prefix: #{inspect(prefix)}", else: "without a prefix"

          raise """
          Arcana.Graph.Migration.down/1 can't remove the graph schema because objects Arcana does not own depend on it:

          #{listed}

          Drop or repoint these objects, then retry #{retry_scope}. Nothing was changed. Arcana will not use DROP ... CASCADE because that would delete host-owned objects.
          """
      end
    end)
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
          "WHERE c.relname = $1 AND " <> SchemaScope.visible("c", "n", "$2"),
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

  # Anchored, so only a comment that is exactly the marker counts. An
  # unanchored match read a version out of any prose that happened to
  # contain "arcana_graph:2", and a bare integer (what Oban stores) would read a
  # host's own "1" as version 1. Anything we don't recognise reads as 0,
  # which is the same answer as "never installed" - see the moduledoc.
  defp parse_version(comment), do: Registry.parse_marker(:graph, comment)

  defp record_version(0, _prefix), do: :ok

  defp record_version(version, prefix) do
    execute(
      "COMMENT ON TABLE #{qualify(@version_table, prefix)} IS '#{Registry.marker(:graph, version)}'"
    )
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
        Arcana.Graph.Migration,
        "arcana_graph_entities",
        prefix,
        """
        alter the column yourself and re-extract. Note
        `mix arcana.gen.embedding_migration` will not help here: it only
        resizes arcana_chunks.embedding.
        """
      )
    end)
  end

  # Run from up/1 rather than inside change(1, :up, _): that clause is skipped
  # once the recorded version already equals the target, so a database that
  # adopted v1 while still carrying a wrong-shaped legacy index would never
  # have been repaired.
  defp converge_entities_index!(prefix) do
    execute(fn ->
      UniqueIndex.converge!(
        repo(),
        "arcana_graph_entities",
        ["name", "collection_id"],
        prefix,
        &qualify(&1, prefix)
      )
    end)
  end

  defp converge_mentions_index!(prefix) do
    execute(fn ->
      UniqueIndex.converge!(
        repo(),
        "arcana_graph_entity_mentions",
        ["entity_id", "chunk_id"],
        prefix,
        &qualify(&1, prefix)
      )
    end)
  end

  defp converge_v2_indexes!(prefix) do
    execute(fn ->
      UniqueIndex.converge!(
        repo(),
        "arcana_graph_relationships",
        ["fingerprint"],
        prefix,
        &qualify(&1, prefix)
      )

      UniqueIndex.converge!(
        repo(),
        "arcana_graph_relationship_evidence",
        ["relationship_id", "chunk_id"],
        prefix,
        &qualify(&1, prefix),
        name: "arcana_graph_relationship_evidence_rel_chunk_index"
      )
    end)
  end

  defp require_dimensions!(opts) do
    Dimensions.require!(opts, Arcana.Graph.Migration, "arcana_graph_entities")
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
    dimensions = require_dimensions!(opts)
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

    for table_name <- Registry.tables_added_in(:graph, 1) |> Enum.reverse() do
      drop_if_exists(table(String.to_atom(table_name), prefix: prefix))
    end
  end

  # === Version 2 ===

  defp change(2, :up, opts) do
    prefix = Keyword.get(opts, :prefix)

    # Legacy rows carry no chunk provenance. Guessing would let failed or
    # replaced documents keep influencing retrieval, so v2 deliberately
    # discards them and requires a graph rebuild.
    execute(fn ->
      case v2_install_state(prefix) do
        :legacy ->
          repo().query!("DELETE FROM #{qualify("arcana_graph_relationships", prefix)}", [])

          repo().query!(
            "UPDATE #{qualify("arcana_graph_communities", prefix)} " <>
              "SET dirty = true, summary = NULL, summary_fingerprint = NULL",
            []
          )

        :v2 ->
          verify_v2_data!(prefix)

        :partial ->
          raise """
          Arcana found a partial graph migration v2 install.

          The fingerprint column and arcana_graph_relationship_evidence table must
          either both be absent (v1) or both be present with valid provenance (v2).
          Nothing was changed. Restore the schema to one of those states and rerun.
          """
      end
    end)

    execute(
      "ALTER TABLE #{qualify("arcana_graph_relationships", prefix)} " <>
        "ADD COLUMN IF NOT EXISTS fingerprint varchar(64)"
    )

    execute(
      "ALTER TABLE #{qualify("arcana_graph_relationships", prefix)} " <>
        "ALTER COLUMN fingerprint SET NOT NULL"
    )

    create_if_not_exists(
      unique_index(:arcana_graph_relationships, [:fingerprint], prefix: prefix)
    )

    create_if_not_exists table(:arcana_graph_relationship_evidence,
                           primary_key: false,
                           prefix: prefix
                         ) do
      add(:id, :binary_id, primary_key: true)

      add(
        :relationship_id,
        references(:arcana_graph_relationships,
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

      timestamps(updated_at: false)
    end

    create_if_not_exists(
      unique_index(:arcana_graph_relationship_evidence, [:relationship_id, :chunk_id],
        prefix: prefix,
        name: :arcana_graph_relationship_evidence_rel_chunk_index
      )
    )

    create_if_not_exists(index(:arcana_graph_relationship_evidence, [:chunk_id], prefix: prefix))
  end

  defp change(2, :down, opts) do
    prefix = Keyword.get(opts, :prefix)

    for table_name <- Registry.tables_added_in(:graph, 2) |> Enum.reverse() do
      drop_if_exists(table(String.to_atom(table_name), prefix: prefix))
    end

    drop_if_exists(index(:arcana_graph_relationships, [:fingerprint], prefix: prefix))

    execute(
      "ALTER TABLE #{qualify("arcana_graph_relationships", prefix)} " <>
        "DROP COLUMN IF EXISTS fingerprint"
    )
  end

  defp v2_install_state(prefix) do
    fingerprint? = column_exists?("arcana_graph_relationships", "fingerprint", prefix)
    evidence? = table_exists?("arcana_graph_relationship_evidence", prefix)

    evidence_columns? =
      evidence? and
        column_exists?("arcana_graph_relationship_evidence", "relationship_id", prefix) and
        column_exists?("arcana_graph_relationship_evidence", "chunk_id", prefix)

    case {fingerprint?, evidence?, evidence_columns?} do
      {false, false, false} -> :legacy
      {true, true, true} -> :v2
      _mixed -> :partial
    end
  end

  defp verify_v2_data!(prefix) do
    %{rows: [[null_fingerprints, missing_evidence]]} =
      repo().query!(
        "SELECT " <>
          "count(*) FILTER (WHERE r.fingerprint IS NULL), " <>
          "count(*) FILTER (WHERE NOT EXISTS (" <>
          "SELECT 1 FROM #{qualify("arcana_graph_relationship_evidence", prefix)} e " <>
          "WHERE e.relationship_id = r.id)) " <>
          "FROM #{qualify("arcana_graph_relationships", prefix)} r",
        []
      )

    if null_fingerprints > 0 or missing_evidence > 0 do
      raise """
      Arcana found relationship rows that are not valid graph migration v2 data.

      NULL fingerprints: #{null_fingerprints}
      Relationships without chunk evidence: #{missing_evidence}

      Nothing was changed. Repair or remove those rows and rerun the migration.
      """
    end
  end

  defp verify_v2_schema!(prefix) do
    execute(fn ->
      verify_fingerprint_column!(prefix)
      verify_evidence_columns!(prefix)
      verify_evidence_foreign_keys!(prefix)
    end)
  end

  defp verify_fingerprint_column!(prefix) do
    %{rows: rows} =
      repo().query!(
        "SELECT format_type(a.atttypid, a.atttypmod), a.attnotnull " <>
          "FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = 'arcana_graph_relationships' " <>
          "AND a.attname = 'fingerprint' AND NOT a.attisdropped " <>
          "AND " <> SchemaScope.visible("c", "n", "$1"),
        [prefix]
      )

    unless rows == [["character varying(64)", true]] do
      raise "Arcana graph v2 requires fingerprint varchar(64) NOT NULL, got: #{inspect(rows)}"
    end
  end

  defp verify_evidence_columns!(prefix) do
    %{rows: rows} =
      repo().query!(
        "SELECT a.attname, format_type(a.atttypid, a.atttypmod), a.attnotnull " <>
          "FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = 'arcana_graph_relationship_evidence' " <>
          "AND a.attname IN ('relationship_id', 'chunk_id') AND NOT a.attisdropped " <>
          "AND " <> SchemaScope.visible("c", "n", "$1") <> " ORDER BY a.attname",
        [prefix]
      )

    expected = [["chunk_id", "uuid", true], ["relationship_id", "uuid", true]]

    unless rows == expected do
      raise "Arcana graph v2 evidence columns have the wrong shape: #{inspect(rows)}"
    end
  end

  defp verify_evidence_foreign_keys!(prefix) do
    %{rows: rows} =
      repo().query!(
        "SELECT source_attr.attname, target.relname, target_ns.nspname, " <>
          "source_ns.nspname, con.confdeltype " <>
          "FROM pg_constraint con " <>
          "JOIN pg_class source ON source.oid = con.conrelid " <>
          "JOIN pg_namespace source_ns ON source_ns.oid = source.relnamespace " <>
          "JOIN pg_class target ON target.oid = con.confrelid " <>
          "JOIN pg_namespace target_ns ON target_ns.oid = target.relnamespace " <>
          "JOIN LATERAL unnest(con.conkey) WITH ORDINALITY sk(attnum, ord) ON true " <>
          "JOIN pg_attribute source_attr ON source_attr.attrelid = source.oid " <>
          "AND source_attr.attnum = sk.attnum " <>
          "WHERE con.contype = 'f' AND source.relname = 'arcana_graph_relationship_evidence' " <>
          "AND " <>
          SchemaScope.visible("source", "source_ns", "$1") <>
          " " <>
          "ORDER BY source_attr.attname",
        [prefix]
      )

    valid? =
      case rows do
        [
          ["chunk_id", "arcana_chunks", chunk_schema, source_schema, "c"],
          [
            "relationship_id",
            "arcana_graph_relationships",
            relationship_schema,
            source_schema,
            "c"
          ]
        ] ->
          chunk_schema == source_schema and relationship_schema == source_schema

        _ ->
          false
      end

    unless valid? do
      raise "Arcana graph v2 evidence foreign keys have the wrong shape: #{inspect(rows)}"
    end
  end

  defp table_exists?(table, prefix) do
    %{rows: [[exists?]]} =
      repo().query!(
        "SELECT EXISTS (" <>
          "SELECT 1 FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND c.relkind IN ('r', 'p') " <>
          "AND " <> SchemaScope.visible("c", "n", "$2") <> ")",
        [table, prefix]
      )

    exists?
  end

  defp column_exists?(table, column, prefix) do
    %{rows: [[exists?]]} =
      repo().query!(
        "SELECT EXISTS (" <>
          "SELECT 1 FROM pg_attribute a " <>
          "JOIN pg_class c ON c.oid = a.attrelid " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND a.attname = $2 AND NOT a.attisdropped " <>
          "AND " <> SchemaScope.visible("c", "n", "$3") <> ")",
        [table, column, prefix]
      )

    exists?
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
