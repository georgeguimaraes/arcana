defmodule Arcana.Graph.GraphStore.Ecto do
  @moduledoc """
  Ecto/PostgreSQL implementation of the GraphStore behaviour.

  This is the default graph storage backend, storing entities, relationships,
  and mentions in PostgreSQL tables.
  """

  @behaviour Arcana.Graph.GraphStore

  alias Arcana.Graph.{Community, Entity, EntityMention, EntityName, Relationship}
  import Ecto.Query

  # Postgres-side spelling of EntityName.normalize/1, so upserts and
  # lookups match name variants already stored with different
  # casing/underscores.
  #
  # Every comparison normalizes BOTH sides through this SQL rather than
  # comparing an Elixir-computed key against a SQL-computed one: an entity
  # that fails to match itself re-inserts its own name and trips the
  # (name, collection_id) unique index. That keeps the upsert side
  # self-consistent whatever the name carries, but the read path compares a
  # stored name against one an extractor just emitted, so the fold itself
  # still has to be right.
  #
  # Hence the spelled-out whitespace class. Postgres' `\s` follows the
  # database ctype, which does NOT classify NBSP as space — the one
  # character every HTML/PDF-derived name arrives with — so `btrim` (which
  # only strips U+0020) left it in the key and made the stored row
  # unreachable. The class below is the Unicode White_Space set, matching
  # EntityName.normalize/1 character for character.
  #
  # Case folding still differs from Elixir's on an open-ended set of
  # codepoints that depends on the database host's libc (56 of them on
  # PG 16.15/glibc, only U+0130 of which is fixed by Unicode itself), and
  # neither side normalizes NFC/NFD. Both are documented in
  # Arcana.Graph.EntityName; persist_entities/3 keys the raw name so a
  # disagreeing pair still reaches its own row.
  @whitespace_class "[\\u0009-\\u000d\\u0020\\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000]+"
  @normalize_template "btrim(regexp_replace(regexp_replace(lower(EXPR), '[_-]+', ' ', 'g'), '#{@whitespace_class}', ' ', 'g'))"
  @normalize_name_sql String.replace(@normalize_template, "EXPR", "?")
  @normalized_names_match_sql @normalize_name_sql <>
                                " = ANY(SELECT " <>
                                String.replace(@normalize_template, "EXPR", "n") <>
                                " FROM unnest(?::text[]) AS n)"

  # === Storage Callbacks ===

  @impl true
  def persist_entities(collection_id, entities, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Skip the repeat upserts within this call, then let Postgres decide
    # which rows exist. Deduping on the ELIXIR key would decide it here
    # instead: two spellings that share an Elixir key but not a Postgres
    # one ("İstanbul" and its decomposed form) would collapse when they
    # arrived in the same chunk and stay apart when they arrived in
    # different ones — same document, different :chunk_size, different
    # graph. Identical raw names always share a Postgres key, so deduping
    # on the raw name can't decide anything Postgres wouldn't.
    #
    # The key still gates the reject. Both engines agree on which names
    # normalize to empty.
    #
    # The returned map is keyed BOTH ways, because those same two spellings
    # produce two rows and one Elixir key. `{:raw, name}` is the exact key:
    # Postgres decided which row that raw name went to, so it is the only
    # one that can tell the rows apart. Keying on the Elixir key alone let
    # the second upsert overwrite the first, and lookup_entity_id/2 then
    # sent every mention and every relationship endpoint to the second row
    # while the first sat orphaned and unreachable from search/3.
    #
    # The bare normalized key stays as the fallback for names this call
    # never persisted — an earlier chunk's entity reached through the map
    # Arcana.Graph merges across chunks, or a map a caller built itself.
    # First spelling wins it (`put_new`), matching what the map held before
    # the raw keys existed.
    entity_id_map =
      entities
      |> Enum.map(fn entity -> {EntityName.normalize(entity.name), entity} end)
      |> Enum.reject(fn {key, _entity} -> is_nil(key) or key == "" end)
      |> Enum.uniq_by(fn {_key, entity} -> entity.name end)
      |> Enum.reduce(%{}, fn {key, entity}, id_map ->
        entity_record = upsert_entity(entity, collection_id, repo)

        id_map
        |> Map.put({:raw, entity.name}, entity_record.id)
        |> Map.put_new(key, entity_record.id)
      end)

    {:ok, entity_id_map}
  end

  @impl true
  def persist_relationships(relationships, entity_id_map, opts) do
    repo = Keyword.fetch!(opts, :repo)

    relationships
    |> Enum.each(fn rel ->
      source_id = lookup_entity_id(entity_id_map, rel.source)
      target_id = lookup_entity_id(entity_id_map, rel.target)

      if source_id && target_id && rel.type && rel.type != "" do
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: source_id,
          target_id: target_id,
          type: rel.type,
          description: rel[:description],
          strength: rel[:strength],
          metadata: rel[:metadata]
        })
        |> repo.insert!()
      end
    end)

    :ok
  end

  @impl true
  def persist_mentions(mentions, entity_id_map, opts) do
    repo = Keyword.fetch!(opts, :repo)

    mentions
    |> Enum.each(fn mention ->
      entity_id = lookup_entity_id(entity_id_map, mention.entity_name)

      if entity_id do
        %EntityMention{}
        |> EntityMention.changeset(%{
          entity_id: entity_id,
          chunk_id: mention.chunk_id,
          span_start: mention[:span_start],
          span_end: mention[:span_end]
        })
        |> repo.insert!(on_conflict: :nothing)
      end
    end)

    :ok
  end

  # === Query Callbacks ===

  @impl true
  def search(entity_names, collection_ids, opts) do
    repo = Keyword.fetch!(opts, :repo)

    entity_ids = find_entity_ids(entity_names, collection_ids, repo)
    fetch_and_score_chunks(entity_ids, repo)
  end

  @impl true
  def search_by_embedding(query_embedding, collection_ids, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.3)

    base =
      from(e in Entity,
        where: not is_nil(e.embedding),
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          description: e.description,
          distance: fragment("? <=> ?", e.embedding, ^query_embedding)
        }
      )

    # nil means unscoped; a list scopes the query, and an empty list must
    # match nothing (`in []` compiles to false) — never fall back to global.
    base =
      if is_list(collection_ids) do
        from(e in base, where: e.collection_id in ^collection_ids)
      else
        base
      end

    from(e in subquery(base),
      where: e.distance < ^(1.0 - threshold),
      order_by: e.distance,
      limit: ^limit,
      select: %{
        id: e.id,
        name: e.name,
        type: e.type,
        description: e.description,
        similarity: fragment("1 - ?", e.distance)
      }
    )
    |> repo.all()
  end

  @impl true
  def find_entities(collection_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    repo.all(
      from(e in Entity,
        where: e.collection_id == ^collection_id,
        select: %{id: e.id, name: e.name, type: e.type, description: e.description}
      )
    )
  end

  # === Traversal Callbacks ===

  @impl true
  def find_related_entities(entity_id, depth, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Simple BFS traversal using recursive queries
    find_related_bfs([entity_id], MapSet.new([entity_id]), depth, repo)
  end

  # === Community Callbacks ===

  @impl true
  def persist_communities(collection_id, communities, opts) do
    repo = Keyword.fetch!(opts, :repo)

    Enum.each(communities, fn community ->
      %Community{}
      |> Community.changeset(Map.put(community, :collection_id, collection_id))
      |> repo.insert!()
    end)

    :ok
  end

  @impl true
  def get_community_summaries(collection_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    repo.all(
      from(c in Community,
        where: c.collection_id == ^collection_id,
        select: %{id: c.id, level: c.level, summary: c.summary, entity_ids: c.entity_ids}
      )
    )
  end

  # === Deletion Callbacks ===

  @impl true
  def delete_by_chunks([], _opts), do: :ok

  def delete_by_chunks(chunk_ids, opts) when is_list(chunk_ids) do
    repo = Keyword.fetch!(opts, :repo)

    # The entities come back from the delete itself rather than from a read
    # before it. Reading first leaves a window: a concurrent build can add a
    # mention after the read, the delete takes it anyway, and its collection
    # never makes the sweep list, so the new entity is orphaned. Taking a
    # lock instead doesn't close that - the collection can't be locked until
    # it has been discovered. RETURNING has no window at all, and a mention
    # committed after the delete simply isn't deleted.
    {_count, entity_ids} =
      repo.delete_all(
        from(m in EntityMention, where: m.chunk_id in ^chunk_ids, select: m.entity_id)
      )

    # Only the collections these chunks touched: a delete in one tenant must
    # not sweep another tenant's entities.
    collection_ids = collections_for_entities(entity_ids, repo)

    Enum.each(collection_ids, &sweep_orphans(&1, opts))
    sweep_uncollected(entity_ids, repo)

    :ok
  end

  # An entity with no collection has no collection to sweep, so the
  # per-collection pass above can never reach it. The global sweep this
  # replaced did, and dropping that silently would leak those rows forever.
  # Removing them can't cross a tenant boundary, because belonging to no
  # collection is what makes them unreachable in the first place. Nothing
  # in-tree creates one - persist_entities/3 always carries a collection -
  # so this is here for custom graph stores and hand-written rows.
  defp sweep_uncollected([], _repo), do: :ok

  defp sweep_uncollected(entity_ids, repo) do
    mentioned = from(m in EntityMention, select: m.entity_id)

    # Relationships cascade via the FK on source_id/target_id.
    {_count, deleted} =
      repo.delete_all(
        from(e in Entity,
          where:
            e.id in ^Enum.uniq(entity_ids) and is_nil(e.collection_id) and
              e.id not in subquery(mentioned),
          select: e.id
        )
      )

    # A community is collection-less on the same terms its entities are, and
    # it holds their ids in an array rather than through a foreign key, so
    # nothing cascades. Left alone it would keep counting rows that are gone
    # and keep serving a summary describing them.
    mark_communities_dirty(dynamic([c], is_nil(c.collection_id)), deleted || [], repo)

    :ok
  end

  defp collections_for_entities([], _repo), do: []

  defp collections_for_entities(entity_ids, repo) do
    repo.all(
      from(e in Entity,
        where: e.id in ^Enum.uniq(entity_ids) and not is_nil(e.collection_id),
        select: e.collection_id,
        distinct: true
      )
    )
  end

  @impl true
  def delete_by_collection(collection_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Get all entity IDs in this collection
    entity_ids =
      repo.all(from(e in Entity, where: e.collection_id == ^collection_id, select: e.id))

    if entity_ids != [] do
      # Delete mentions for these entities
      repo.delete_all(from(m in EntityMention, where: m.entity_id in ^entity_ids))

      # Delete relationships involving these entities
      repo.delete_all(
        from(r in Relationship, where: r.source_id in ^entity_ids or r.target_id in ^entity_ids)
      )

      # Delete entities
      repo.delete_all(from(e in Entity, where: e.collection_id == ^collection_id))
    end

    # Delete communities
    repo.delete_all(from(c in Community, where: c.collection_id == ^collection_id))

    :ok
  end

  @doc """
  Runs `fun` inside a transaction holding the collection's advisory lock.

  Uses `pg_advisory_xact_lock/1` keyed on the collection, the same idiom
  `Arcana.Ingest` uses for the replace swap. Both the entity/mention
  persist path and `sweep_orphans/2` take it, so a sweep can never land
  between an entity insert and its mention insert.

  Keep the wrapped work to DB writes: the lock blocks every concurrent
  graph write for the collection until the transaction commits.

  Opens a transaction only when there isn't one already. A nested Ecto
  transaction never isolated anything - it joins the outer one - but it does
  make DBConnection mark the connection aborted when the wrapped work fails,
  which refuses every later statement including a caller's
  `ROLLBACK TO SAVEPOINT`. Skipping it costs nothing, because
  `pg_advisory_xact_lock/1` binds to the enclosing transaction either way.
  """
  @impl true
  def with_write_lock(collection_id, opts, fun) when is_function(fun, 0) do
    repo = Keyword.fetch!(opts, :repo)

    if repo.in_transaction?() do
      take_write_lock(repo, collection_id)
      fun.()
    else
      {:ok, result} =
        repo.transaction(fn ->
          take_write_lock(repo, collection_id)
          fun.()
        end)

      result
    end
  end

  defp take_write_lock(repo, collection_id) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "arcana:graph:#{collection_id}"
    ])
  end

  @doc """
  Deletes entities in the collection that have no remaining mentions.

  Runs under the collection's write lock (see `with_write_lock/3`) so it
  cannot delete an entity a concurrent build has inserted but not yet
  mentioned. Relationships cascade via FK; communities overlapping the
  deleted entities are marked dirty.
  """
  @impl true
  def sweep_orphans(collection_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with_write_lock(collection_id, opts, fn ->
      orphaned_ids =
        repo.all(
          from(e in Entity,
            left_join: m in EntityMention,
            on: m.entity_id == e.id,
            where: e.collection_id == ^collection_id,
            group_by: e.id,
            having: count(m.id) == 0,
            select: e.id
          )
        )

      if orphaned_ids != [] do
        # Relationships cascade via FK on source_id/target_id
        repo.delete_all(from(e in Entity, where: e.id in ^orphaned_ids))
        mark_overlapping_communities_dirty(collection_id, orphaned_ids, repo)
      end

      :ok
    end)
  end

  # Also drops the swept ids from entity_ids: the community stays dirty
  # until the next summarize pass, but until then its entity_count would
  # otherwise keep counting entities that no longer exist.
  defp mark_overlapping_communities_dirty(collection_id, entity_ids, repo) do
    mark_communities_dirty(dynamic([c], c.collection_id == ^collection_id), entity_ids, repo)
  end

  defp mark_communities_dirty(_scope, [], _repo), do: :ok

  defp mark_communities_dirty(scope, entity_ids, repo) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    repo.update_all(
      from(c in Community,
        where: ^scope,
        where: fragment("? && ?", c.entity_ids, type(^entity_ids, {:array, Ecto.UUID})),
        update: [
          set: [
            dirty: true,
            updated_at: ^now,
            entity_ids:
              fragment(
                "ARRAY(SELECT x FROM unnest(?) AS x WHERE NOT (x = ANY(?)))",
                c.entity_ids,
                type(^entity_ids, {:array, Ecto.UUID})
              )
          ]
        ]
      ),
      []
    )
  end

  # === Detail Query Callbacks ===

  @impl true
  def get_entity(entity_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.one(from(e in Entity, where: e.id == ^entity_id)) do
      nil ->
        {:error, :not_found}

      entity ->
        {:ok,
         %{
           id: entity.id,
           name: entity.name,
           type: entity.type,
           description: entity.description,
           collection_id: entity.collection_id,
           metadata: entity.metadata
         }}
    end
  end

  @impl true
  def get_relationships(entity_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    repo.all(
      from(r in Relationship,
        join: source in Entity,
        on: source.id == r.source_id,
        join: target in Entity,
        on: target.id == r.target_id,
        where: r.source_id == ^entity_id or r.target_id == ^entity_id,
        select: %{
          id: r.id,
          type: r.type,
          strength: r.strength,
          description: r.description,
          source_id: source.id,
          source_name: source.name,
          source_type: source.type,
          target_id: target.id,
          target_name: target.name,
          target_type: target.type
        }
      )
    )
  end

  @impl true
  def get_relationship(relationship_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.one(
           from(r in Relationship,
             join: source in Entity,
             on: source.id == r.source_id,
             join: target in Entity,
             on: target.id == r.target_id,
             where: r.id == ^relationship_id,
             select: %{
               id: r.id,
               type: r.type,
               strength: r.strength,
               description: r.description,
               source_id: source.id,
               source_name: source.name,
               source_type: source.type,
               target_id: target.id,
               target_name: target.name,
               target_type: target.type
             }
           )
         ) do
      nil -> {:error, :not_found}
      relationship -> {:ok, relationship}
    end
  end

  @impl true
  def get_mentions(entity_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 5)

    repo.all(
      from(m in EntityMention,
        join: c in Arcana.Chunk,
        on: c.id == m.chunk_id,
        where: m.entity_id == ^entity_id,
        limit: ^limit,
        select: %{
          id: m.id,
          context: m.context,
          chunk_id: c.id,
          chunk_text: c.text,
          document_id: c.document_id
        }
      )
    )
  end

  @impl true
  def get_community(community_id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.one(
           from(c in Community,
             where: c.id == ^community_id,
             select: %{
               id: c.id,
               level: c.level,
               summary: c.summary,
               entity_ids: c.entity_ids,
               collection_id: c.collection_id,
               dirty: c.dirty
             }
           )
         ) do
      nil -> {:error, :not_found}
      community -> {:ok, community}
    end
  end

  # === List Callbacks (for UI) ===

  @impl true
  def list_entities(opts) do
    repo = Keyword.fetch!(opts, :repo)
    collection_id = Keyword.get(opts, :collection_id)
    type_filter = Keyword.get(opts, :type)
    search = Keyword.get(opts, :search)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    # Subquery for mention counts
    mention_counts =
      from(m in EntityMention,
        group_by: m.entity_id,
        select: %{entity_id: m.entity_id, count: count(m.id)}
      )

    # Subquery for relationship counts (source + target)
    source_counts =
      from(r in Relationship,
        group_by: r.source_id,
        select: %{entity_id: r.source_id, count: count(r.id)}
      )

    target_counts =
      from(r in Relationship,
        group_by: r.target_id,
        select: %{entity_id: r.target_id, count: count(r.id)}
      )

    query =
      from(e in Entity,
        join: c in Arcana.Collection,
        on: c.id == e.collection_id,
        left_join: mc in subquery(mention_counts),
        on: mc.entity_id == e.id,
        left_join: sc in subquery(source_counts),
        on: sc.entity_id == e.id,
        left_join: tc in subquery(target_counts),
        on: tc.entity_id == e.id,
        order_by: [desc: coalesce(mc.count, 0)],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          description: e.description,
          collection_id: e.collection_id,
          collection: c.name,
          mention_count: coalesce(mc.count, 0),
          relationship_count: coalesce(sc.count, 0) + coalesce(tc.count, 0)
        }
      )

    query =
      if collection_id, do: where(query, [e], e.collection_id == ^collection_id), else: query

    query =
      if type_filter && type_filter != "",
        do: where(query, [e], e.type == ^type_filter),
        else: query

    query =
      if search && search != "" do
        pattern = "%#{search}%"
        where(query, [e], ilike(e.name, ^pattern))
      else
        query
      end

    repo.all(query)
  end

  @impl true
  def list_relationships(opts) do
    repo = Keyword.fetch!(opts, :repo)
    collection_id = Keyword.get(opts, :collection_id)
    type_filter = Keyword.get(opts, :type)
    search = Keyword.get(opts, :search)
    strength_filter = Keyword.get(opts, :strength)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    from(r in Relationship,
      join: source in Entity,
      on: source.id == r.source_id,
      join: target in Entity,
      on: target.id == r.target_id,
      join: c in Arcana.Collection,
      on: c.id == source.collection_id,
      order_by: [desc: r.strength],
      limit: ^limit,
      offset: ^offset,
      select: %{
        id: r.id,
        type: r.type,
        strength: r.strength,
        description: r.description,
        source_id: source.id,
        source_name: source.name,
        source_type: source.type,
        target_id: target.id,
        target_name: target.name,
        target_type: target.type,
        collection: c.name
      }
    )
    |> maybe_filter_by_collection(collection_id)
    |> maybe_filter_by_type(type_filter)
    |> maybe_filter_by_strength(strength_filter)
    |> maybe_filter_by_relationship_search(search)
    |> repo.all()
  end

  @impl true
  def list_communities(opts) do
    repo = Keyword.fetch!(opts, :repo)
    collection_id = Keyword.get(opts, :collection_id)
    level_filter = Keyword.get(opts, :level)
    search = Keyword.get(opts, :search)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from(comm in Community,
        join: c in Arcana.Collection,
        on: c.id == comm.collection_id,
        order_by: [asc: comm.level, desc: comm.updated_at],
        limit: ^limit,
        offset: ^offset,
        select: %{
          id: comm.id,
          level: comm.level,
          summary: comm.summary,
          entity_ids: comm.entity_ids,
          collection: c.name,
          dirty: comm.dirty
        }
      )

    query =
      if collection_id,
        do: where(query, [comm], comm.collection_id == ^collection_id),
        else: query

    query = if level_filter, do: where(query, [comm], comm.level == ^level_filter), else: query

    query =
      if search && search != "" do
        pattern = "%#{search}%"
        where(query, [comm], ilike(comm.summary, ^pattern))
      else
        query
      end

    repo.all(query)
    |> Enum.map(fn c ->
      Map.put(c, :entity_count, length(c.entity_ids || []))
    end)
  end

  # === Private Helpers ===

  # Raw name first: persist_entities/3 keyed it off what Postgres did with
  # that exact spelling, and two spellings sharing a normalized key can
  # still be two rows. The normalized key second, for names this call never
  # persisted — see the comment in persist_entities/3.
  defp lookup_entity_id(entity_id_map, name) do
    Map.get(entity_id_map, {:raw, name}) ||
      Map.get(entity_id_map, EntityName.normalize(name))
  end

  defp upsert_entity(entity, collection_id, repo) do
    # Match on the normalized name so stored variants ("Delivery" vs
    # "delivery") upsert into one row. Both sides go through the SQL
    # normalization (see @normalize_template): comparing against an
    # Elixir-computed key makes an entity miss itself whenever the two
    # engines disagree, and the re-insert then hits the unique index.
    # Legacy data may already hold several variants, so take the oldest
    # instead of expecting one.
    #
    # The select-then-insert is only safe because callers hold the
    # collection's write lock (see with_write_lock/3); without it two
    # concurrent builds could both miss and insert competing variants.
    # There is no unique index on the normalized expression precisely
    # because legacy rows may already violate it.
    existing =
      repo.one(
        from(e in Entity,
          where:
            e.collection_id == ^collection_id and
              fragment(@normalize_name_sql, e.name) ==
                fragment(@normalize_name_sql, type(^entity.name, :string)),
          order_by: [asc: e.inserted_at],
          limit: 1
        )
      )

    case existing do
      nil ->
        %Entity{}
        |> Entity.changeset(%{
          name: entity.name,
          type: entity.type,
          description: entity[:description],
          embedding: entity[:embedding],
          collection_id: collection_id,
          metadata: entity[:metadata]
        })
        |> repo.insert!()

      %{embedding: nil} ->
        if entity[:embedding] do
          existing
          |> Entity.changeset(%{embedding: entity[:embedding]})
          |> repo.update!()
        else
          existing
        end

      entity_record ->
        entity_record
    end
  end

  defp find_entity_ids([], _collection_ids, _repo), do: []

  defp find_entity_ids(entity_names, collection_ids, repo) do
    # Match normalized names, not raw ones: the write side collapses
    # variants onto one row that keeps its first-seen display name, so a
    # stored "Two_Year_Limited_Warranty" is unreachable from the "two year
    # limited warranty" a query-time extractor emits. Both sides normalize
    # through the same SQL for the reasons in @normalize_template.
    query =
      from(e in Entity,
        where:
          fragment(
            @normalized_names_match_sql,
            e.name,
            type(^entity_names, {:array, :string})
          ),
        select: e.id
      )

    query =
      if is_list(collection_ids),
        do: from(e in query, where: e.collection_id in ^collection_ids),
        else: query

    repo.all(query)
  end

  defp fetch_and_score_chunks([], _repo), do: []

  defp fetch_and_score_chunks(entity_ids, repo) do
    chunk_ids =
      repo.all(
        from(m in EntityMention,
          where: m.entity_id in ^entity_ids,
          select: m.chunk_id,
          distinct: true
        )
      )

    score_chunks(chunk_ids, entity_ids, repo)
  end

  defp score_chunks([], _entity_ids, _repo), do: []

  defp score_chunks(chunk_ids, entity_ids, repo) do
    chunk_ids
    |> Enum.map(&score_chunk(&1, entity_ids, repo))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp score_chunk(chunk_id, entity_ids, repo) do
    mention_count =
      repo.one(
        from(m in EntityMention,
          where: m.chunk_id == ^chunk_id and m.entity_id in ^entity_ids,
          select: count()
        )
      )

    %{
      chunk_id: chunk_id,
      score: mention_count * 0.1
    }
  end

  defp find_related_bfs(_current_ids, visited, 0, repo), do: entities_from_ids(visited, repo)

  defp find_related_bfs([], visited, _depth, repo), do: entities_from_ids(visited, repo)

  defp find_related_bfs(current_ids, visited, depth, repo) do
    # Find all entities connected to current_ids
    related_ids =
      repo.all(
        from(r in Relationship,
          where: r.source_id in ^current_ids or r.target_id in ^current_ids,
          select: {r.source_id, r.target_id}
        )
      )
      |> Enum.flat_map(fn {source, target} -> [source, target] end)
      |> Enum.reject(&MapSet.member?(visited, &1))
      |> Enum.uniq()

    new_visited = Enum.reduce(related_ids, visited, &MapSet.put(&2, &1))

    find_related_bfs(related_ids, new_visited, depth - 1, repo)
  end

  defp entities_from_ids(id_set, repo) do
    ids = MapSet.to_list(id_set)

    if ids == [] do
      []
    else
      repo.all(
        from(e in Entity,
          where: e.id in ^ids,
          select: %{id: e.id, name: e.name, type: e.type, description: e.description}
        )
      )
    end
  end

  defp maybe_filter_by_collection(query, nil), do: query

  defp maybe_filter_by_collection(query, collection_id) do
    where(query, [_r, source], source.collection_id == ^collection_id)
  end

  defp maybe_filter_by_type(query, nil), do: query
  defp maybe_filter_by_type(query, ""), do: query

  defp maybe_filter_by_type(query, type_filter) do
    where(query, [r], r.type == ^type_filter)
  end

  defp maybe_filter_by_strength(query, nil), do: query
  defp maybe_filter_by_strength(query, :strong), do: where(query, [r], r.strength >= 7)
  defp maybe_filter_by_strength(query, "strong"), do: where(query, [r], r.strength >= 7)

  defp maybe_filter_by_strength(query, :medium),
    do: where(query, [r], r.strength >= 4 and r.strength < 7)

  defp maybe_filter_by_strength(query, "medium"),
    do: where(query, [r], r.strength >= 4 and r.strength < 7)

  defp maybe_filter_by_strength(query, :weak), do: where(query, [r], r.strength < 4)
  defp maybe_filter_by_strength(query, "weak"), do: where(query, [r], r.strength < 4)
  defp maybe_filter_by_strength(query, _), do: query

  defp maybe_filter_by_relationship_search(query, nil), do: query
  defp maybe_filter_by_relationship_search(query, ""), do: query

  defp maybe_filter_by_relationship_search(query, search) do
    pattern = "%#{search}%"

    where(
      query,
      [r, source, target],
      ilike(source.name, ^pattern) or ilike(target.name, ^pattern) or ilike(r.type, ^pattern)
    )
  end
end
