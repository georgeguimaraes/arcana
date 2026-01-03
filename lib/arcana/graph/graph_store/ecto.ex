defmodule Arcana.Graph.GraphStore.Ecto do
  @moduledoc """
  Ecto/PostgreSQL implementation of the GraphStore behaviour.

  This is the default graph storage backend, storing entities, relationships,
  and mentions in PostgreSQL tables.
  """

  @behaviour Arcana.Graph.GraphStore

  alias Arcana.Graph.{Entity, Relationship, EntityMention, Community}
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
end
