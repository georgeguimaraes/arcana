defmodule Arcana.Graph.GraphStore.Ecto do
  @moduledoc """
  Ecto/PostgreSQL implementation of the GraphStore behaviour.

  This is the default graph storage backend, storing entities, relationships,
  and mentions in PostgreSQL tables.
  """

  @behaviour Arcana.Graph.GraphStore

  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship}
  import Ecto.Query

  # === Storage Callbacks ===

  @impl true
  def persist_entities(collection_id, entities, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Deduplicate by name
    unique_entities =
      entities
      |> Enum.reduce(%{}, fn entity, acc ->
        Map.put_new(acc, entity.name, entity)
      end)
      |> Map.values()

    # Upsert each entity and build name -> id mapping
    entity_id_map =
      unique_entities
      |> Enum.reduce(%{}, fn entity, id_map ->
        entity_record = upsert_entity(entity, collection_id, repo)
        Map.put(id_map, entity.name, entity_record.id)
      end)

    {:ok, entity_id_map}
  end

  @impl true
  def persist_relationships(relationships, entity_id_map, opts) do
    repo = Keyword.fetch!(opts, :repo)

    relationships
    |> Enum.each(fn rel ->
      source_id = Map.get(entity_id_map, rel.source)
      target_id = Map.get(entity_id_map, rel.target)

      if source_id && target_id do
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: source_id,
          target_id: target_id,
          type: rel.type,
          description: rel[:description],
          strength: rel[:strength]
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
      entity_id = Map.get(entity_id_map, mention.entity_name)

      if entity_id do
        %EntityMention{}
        |> EntityMention.changeset(%{
          entity_id: entity_id,
          chunk_id: mention.chunk_id,
          span_start: mention[:span_start],
          span_end: mention[:span_end]
        })
        |> repo.insert!()
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
  def delete_by_chunks(chunk_ids, opts) when is_list(chunk_ids) do
    repo = Keyword.fetch!(opts, :repo)

    if chunk_ids == [] do
      :ok
    else
      # Delete mentions for these chunks
      {_count, _} =
        repo.delete_all(from(m in EntityMention, where: m.chunk_id in ^chunk_ids))

      # Find and delete orphaned entities (entities with no remaining mentions)
      delete_orphaned_entities(repo)

      :ok
    end
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
           collection_id: entity.collection_id
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

  defp upsert_entity(entity, collection_id, repo) do
    existing =
      repo.one(
        from(e in Entity,
          where: e.name == ^entity.name and e.collection_id == ^collection_id
        )
      )

    case existing do
      nil ->
        %Entity{}
        |> Entity.changeset(%{
          name: entity.name,
          type: entity.type,
          description: entity[:description],
          collection_id: collection_id
        })
        |> repo.insert!()

      entity_record ->
        entity_record
    end
  end

  defp find_entity_ids([], _collection_ids, _repo), do: []

  defp find_entity_ids(entity_names, collection_ids, repo) do
    query = from(e in Entity, where: e.name in ^entity_names, select: e.id)

    query =
      if collection_ids && collection_ids != [],
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

  defp delete_orphaned_entities(repo) do
    # Find entities with no mentions
    orphaned_ids =
      repo.all(
        from(e in Entity,
          left_join: m in EntityMention,
          on: m.entity_id == e.id,
          group_by: e.id,
          having: count(m.id) == 0,
          select: e.id
        )
      )

    if orphaned_ids != [] do
      # Delete relationships involving orphaned entities
      repo.delete_all(
        from(r in Relationship,
          where: r.source_id in ^orphaned_ids or r.target_id in ^orphaned_ids
        )
      )

      # Delete the orphaned entities
      repo.delete_all(from(e in Entity, where: e.id in ^orphaned_ids))
    end

    :ok
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
