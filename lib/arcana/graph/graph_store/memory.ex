defmodule Arcana.Graph.GraphStore.Memory do
  @moduledoc """
  In-memory implementation of the GraphStore behaviour.

  Uses GenServer to store graph data in memory. Useful for testing
  and small-scale applications that don't need persistence.

  ## Usage

      # Start a memory store
      {:ok, pid} = GraphStore.Memory.start_link([])

      # Use in tests
      Arcana.ingest(text, graph_store: {:memory, pid: pid})

      # Use with named process
      {:ok, _} = GraphStore.Memory.start_link(name: :test_graph)
      Arcana.ingest(text, graph_store: {:memory, name: :test_graph})

  """

  use GenServer

  @behaviour Arcana.Graph.GraphStore

  # === Client API ===

  @doc """
  Starts a memory graph store.

  ## Options

    * `:name` - Optional name for the GenServer process

  """
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, %{}, name: name)
    else
      GenServer.start_link(__MODULE__, %{})
    end
  end

  # === Behaviour Callbacks ===

  @impl Arcana.Graph.GraphStore
  def persist_entities(collection_id, entities, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_entities, collection_id, entities})
  end

  @impl Arcana.Graph.GraphStore
  def persist_relationships(relationships, entity_id_map, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_relationships, relationships, entity_id_map})
  end

  @impl Arcana.Graph.GraphStore
  def persist_mentions(mentions, entity_id_map, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_mentions, mentions, entity_id_map})
  end

  @impl Arcana.Graph.GraphStore
  def search(entity_names, collection_ids, opts) do
    server = get_server(opts)
    GenServer.call(server, {:search, entity_names, collection_ids})
  end

  @impl Arcana.Graph.GraphStore
  def find_entities(collection_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:find_entities, collection_id})
  end

  @impl Arcana.Graph.GraphStore
  def find_related_entities(entity_id, depth, opts) do
    server = get_server(opts)
    GenServer.call(server, {:find_related_entities, entity_id, depth})
  end

  @impl Arcana.Graph.GraphStore
  def persist_communities(collection_id, communities, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_communities, collection_id, communities})
  end

  @impl Arcana.Graph.GraphStore
  def get_community_summaries(collection_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_community_summaries, collection_id})
  end

  @impl Arcana.Graph.GraphStore
  def delete_by_chunks(chunk_ids, opts) do
    server = get_server(opts)
    GenServer.call(server, {:delete_by_chunks, chunk_ids})
  end

  @impl Arcana.Graph.GraphStore
  def delete_by_collection(collection_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:delete_by_collection, collection_id})
  end

  @impl Arcana.Graph.GraphStore
  def get_entity(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_entity, entity_id})
  end

  @impl Arcana.Graph.GraphStore
  def get_relationships(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_relationships, entity_id})
  end

  @impl Arcana.Graph.GraphStore
  def get_relationship(relationship_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_relationship, relationship_id})
  end

  @impl Arcana.Graph.GraphStore
  def get_mentions(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_mentions, entity_id})
  end

  @impl Arcana.Graph.GraphStore
  def get_community(community_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_community, community_id})
  end

  @impl Arcana.Graph.GraphStore
  def list_entities(opts) do
    server = get_server(opts)
    GenServer.call(server, {:list_entities, opts})
  end

  @impl Arcana.Graph.GraphStore
  def list_relationships(opts) do
    server = get_server(opts)
    GenServer.call(server, {:list_relationships, opts})
  end

  @impl Arcana.Graph.GraphStore
  def list_communities(opts) do
    server = get_server(opts)
    GenServer.call(server, {:list_communities, opts})
  end

  # === GenServer Callbacks ===

  @impl GenServer
  def init(_opts) do
    state = %{
      entities: %{},
      relationships: [],
      mentions: [],
      communities: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:persist_entities, collection_id, entities}, _from, state) do
    # Deduplicate by name
    unique_entities =
      entities
      |> Enum.reduce(%{}, fn entity, acc ->
        Map.put_new(acc, entity.name, entity)
      end)
      |> Map.values()

    # Get existing entities for this collection
    existing = Map.get(state.entities, collection_id, [])
    existing_by_name = Map.new(existing, fn e -> {e.name, e} end)

    # Upsert and build id map
    {new_entities, id_map} =
      Enum.reduce(unique_entities, {existing, %{}}, fn entity, {ents, ids} ->
        case Map.get(existing_by_name, entity.name) do
          nil ->
            # Insert new entity
            new_entity =
              Map.merge(entity, %{
                id: Ecto.UUID.generate(),
                collection_id: collection_id
              })

            {[new_entity | ents], Map.put(ids, entity.name, new_entity.id)}

          existing_entity ->
            # Return existing
            {ents, Map.put(ids, entity.name, existing_entity.id)}
        end
      end)

    new_state = put_in(state.entities[collection_id], new_entities)
    {:reply, {:ok, id_map}, new_state}
  end

  @impl GenServer
  def handle_call({:persist_relationships, relationships, entity_id_map}, _from, state) do
    valid_relationships =
      relationships
      |> Enum.filter(fn rel ->
        Map.has_key?(entity_id_map, rel.source) and Map.has_key?(entity_id_map, rel.target)
      end)
      |> Enum.map(fn rel ->
        %{
          id: Ecto.UUID.generate(),
          source_id: entity_id_map[rel.source],
          target_id: entity_id_map[rel.target],
          type: rel.type,
          description: rel[:description],
          strength: rel[:strength]
        }
      end)

    new_state = %{state | relationships: state.relationships ++ valid_relationships}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:persist_mentions, mentions, entity_id_map}, _from, state) do
    valid_mentions =
      mentions
      |> Enum.filter(fn m -> Map.has_key?(entity_id_map, m.entity_name) end)
      |> Enum.map(fn m ->
        %{
          id: Ecto.UUID.generate(),
          entity_id: entity_id_map[m.entity_name],
          chunk_id: m.chunk_id,
          span_start: m[:span_start],
          span_end: m[:span_end]
        }
      end)

    new_state = %{state | mentions: state.mentions ++ valid_mentions}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:search, entity_names, collection_ids}, _from, state) do
    # Find entity IDs matching names
    entity_ids =
      state.entities
      |> filter_by_collections(collection_ids)
      |> Enum.flat_map(fn {_cid, entities} -> entities end)
      |> Enum.filter(fn e -> e.name in entity_names end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if MapSet.size(entity_ids) == 0 do
      {:reply, [], state}
    else
      # Find chunks with mentions of these entities
      chunk_scores =
        state.mentions
        |> Enum.filter(fn m -> MapSet.member?(entity_ids, m.entity_id) end)
        |> Enum.group_by(& &1.chunk_id)
        |> Enum.map(fn {chunk_id, mentions} ->
          %{chunk_id: chunk_id, score: length(mentions) * 0.1}
        end)
        |> Enum.sort_by(& &1.score, :desc)

      {:reply, chunk_scores, state}
    end
  end

  @impl GenServer
  def handle_call({:find_entities, collection_id}, _from, state) do
    entities =
      state.entities
      |> Map.get(collection_id, [])
      |> Enum.map(fn e ->
        %{id: e.id, name: e.name, type: e.type, description: e[:description]}
      end)

    {:reply, entities, state}
  end

  @impl GenServer
  def handle_call({:find_related_entities, entity_id, depth}, _from, state) do
    # BFS traversal
    visited = find_related_bfs([entity_id], MapSet.new([entity_id]), depth, state.relationships)

    entities =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Enum.filter(fn e -> MapSet.member?(visited, e.id) end)
      |> Enum.map(fn e ->
        %{id: e.id, name: e.name, type: e.type, description: e[:description]}
      end)

    {:reply, entities, state}
  end

  @impl GenServer
  def handle_call({:persist_communities, collection_id, communities}, _from, state) do
    new_communities = Map.put(state.communities, collection_id, communities)
    {:reply, :ok, %{state | communities: new_communities}}
  end

  @impl GenServer
  def handle_call({:get_community_summaries, collection_id}, _from, state) do
    communities =
      state.communities
      |> Map.get(collection_id, [])
      |> Enum.map(fn c ->
        %{id: c.id, level: c.level, summary: c.summary, entity_ids: c.entity_ids}
      end)

    {:reply, communities, state}
  end

  @impl GenServer
  def handle_call({:delete_by_chunks, chunk_ids}, _from, state) do
    chunk_id_set = MapSet.new(chunk_ids)

    # Remove mentions for these chunks
    new_mentions =
      Enum.reject(state.mentions, fn m -> MapSet.member?(chunk_id_set, m.chunk_id) end)

    # Find entity IDs that still have mentions
    entities_with_mentions =
      new_mentions
      |> Enum.map(& &1.entity_id)
      |> MapSet.new()

    # Remove orphaned entities (entities with no remaining mentions)
    new_entities =
      state.entities
      |> Enum.map(fn {collection_id, entities} ->
        filtered = Enum.filter(entities, fn e -> MapSet.member?(entities_with_mentions, e.id) end)
        {collection_id, filtered}
      end)
      |> Map.new()

    # Get remaining entity IDs
    remaining_entity_ids =
      new_entities
      |> Enum.flat_map(fn {_cid, ents} -> Enum.map(ents, & &1.id) end)
      |> MapSet.new()

    # Remove relationships referencing deleted entities
    new_relationships =
      Enum.filter(state.relationships, fn r ->
        MapSet.member?(remaining_entity_ids, r.source_id) and
          MapSet.member?(remaining_entity_ids, r.target_id)
      end)

    new_state = %{
      state
      | mentions: new_mentions,
        entities: new_entities,
        relationships: new_relationships
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:delete_by_collection, collection_id}, _from, state) do
    # Get entity IDs being deleted
    deleted_entity_ids =
      state.entities
      |> Map.get(collection_id, [])
      |> Enum.map(& &1.id)
      |> MapSet.new()

    # Remove entities for this collection
    new_entities = Map.delete(state.entities, collection_id)

    # Remove relationships involving deleted entities
    new_relationships =
      Enum.reject(state.relationships, fn r ->
        MapSet.member?(deleted_entity_ids, r.source_id) or
          MapSet.member?(deleted_entity_ids, r.target_id)
      end)

    # Remove mentions for deleted entities
    new_mentions =
      Enum.reject(state.mentions, fn m -> MapSet.member?(deleted_entity_ids, m.entity_id) end)

    # Remove communities for this collection
    new_communities = Map.delete(state.communities, collection_id)

    new_state = %{
      state
      | entities: new_entities,
        relationships: new_relationships,
        mentions: new_mentions,
        communities: new_communities
    }

    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:get_entity, entity_id}, _from, state) do
    entity =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Enum.find(fn e -> e.id == entity_id end)

    result =
      case entity do
        nil -> {:error, :not_found}
        e -> {:ok, e}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_relationships, entity_id}, _from, state) do
    # Build entity lookup for names
    entity_by_id =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Map.new(fn e -> {e.id, e} end)

    relationships =
      state.relationships
      |> Enum.filter(fn r -> r.source_id == entity_id or r.target_id == entity_id end)
      |> Enum.map(fn r ->
        source = Map.get(entity_by_id, r.source_id)
        target = Map.get(entity_by_id, r.target_id)

        %{
          id: r.id,
          type: r.type,
          description: r.description,
          strength: r.strength,
          source_id: r.source_id,
          target_id: r.target_id,
          source_name: source && source.name,
          target_name: target && target.name
        }
      end)

    {:reply, relationships, state}
  end

  @impl GenServer
  def handle_call({:get_relationship, relationship_id}, _from, state) do
    # Build entity lookup for names
    entity_by_id =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Map.new(fn e -> {e.id, e} end)

    relationship = Enum.find(state.relationships, fn r -> r.id == relationship_id end)

    result =
      case relationship do
        nil ->
          {:error, :not_found}

        r ->
          source = Map.get(entity_by_id, r.source_id)
          target = Map.get(entity_by_id, r.target_id)

          {:ok,
           %{
             id: r.id,
             type: r.type,
             description: r.description,
             strength: r.strength,
             source_id: r.source_id,
             target_id: r.target_id,
             source: source,
             target: target
           }}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_mentions, entity_id}, _from, state) do
    # Note: In memory backend, we don't have chunk text - just return mention structure
    mentions =
      state.mentions
      |> Enum.filter(fn m -> m.entity_id == entity_id end)
      |> Enum.map(fn m ->
        %{
          id: m.id,
          entity_id: m.entity_id,
          chunk_id: m.chunk_id,
          span_start: m.span_start,
          span_end: m.span_end,
          chunk_text: nil
        }
      end)

    {:reply, mentions, state}
  end

  @impl GenServer
  def handle_call({:get_community, community_id}, _from, state) do
    community =
      state.communities
      |> Enum.flat_map(fn {_cid, comms} -> comms end)
      |> Enum.find(fn c -> c.id == community_id end)

    result =
      case community do
        nil -> {:error, :not_found}
        c -> {:ok, c}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:list_entities, opts}, _from, state) do
    collection_id = Keyword.get(opts, :collection_id)
    type_filter = Keyword.get(opts, :type)
    search_filter = Keyword.get(opts, :search)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    # Start with all entities or filter by collection
    entities =
      if collection_id do
        Map.get(state.entities, collection_id, [])
      else
        Enum.flat_map(state.entities, fn {_cid, ents} -> ents end)
      end

    # Count mentions per entity
    mention_counts =
      state.mentions
      |> Enum.group_by(& &1.entity_id)
      |> Map.new(fn {eid, mentions} -> {eid, length(mentions)} end)

    # Count relationships per entity
    relationship_counts =
      state.relationships
      |> Enum.flat_map(fn r -> [r.source_id, r.target_id] end)
      |> Enum.frequencies()

    entities
    |> maybe_filter_by_type(type_filter)
    |> maybe_filter_by_search(search_filter)
    |> Enum.map(fn e ->
      %{
        id: e.id,
        name: e.name,
        type: e.type,
        description: e[:description],
        collection_id: e.collection_id,
        mention_count: Map.get(mention_counts, e.id, 0),
        relationship_count: Map.get(relationship_counts, e.id, 0)
      }
    end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> then(fn result -> {:reply, result, state} end)
  end

  @impl GenServer
  def handle_call({:list_relationships, opts}, _from, state) do
    collection_id = Keyword.get(opts, :collection_id)
    type_filter = Keyword.get(opts, :type)
    search_filter = Keyword.get(opts, :search)
    strength_filter = Keyword.get(opts, :strength)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    # Build entity lookup
    entity_by_id =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Map.new(fn e -> {e.id, e} end)

    # Get entity IDs in collection (if filtering)
    collection_entity_ids =
      if collection_id do
        state.entities
        |> Map.get(collection_id, [])
        |> Enum.map(& &1.id)
        |> MapSet.new()
      else
        nil
      end

    relationships =
      state.relationships
      |> maybe_filter_rels_by_collection(collection_entity_ids)
      |> maybe_filter_rels_by_type(type_filter)
      |> maybe_filter_rels_by_strength(strength_filter)
      |> Enum.map(fn r ->
        source = Map.get(entity_by_id, r.source_id)
        target = Map.get(entity_by_id, r.target_id)

        %{
          id: r.id,
          type: r.type,
          description: r.description,
          strength: r.strength,
          source_id: r.source_id,
          target_id: r.target_id,
          source_name: source && source.name,
          target_name: target && target.name,
          collection_id: source && source.collection_id
        }
      end)
      |> maybe_filter_rels_by_search(search_filter)
      |> Enum.drop(offset)
      |> Enum.take(limit)

    {:reply, relationships, state}
  end

  @impl GenServer
  def handle_call({:list_communities, opts}, _from, state) do
    collection_id = Keyword.get(opts, :collection_id)
    level_filter = Keyword.get(opts, :level)
    search_filter = Keyword.get(opts, :search)
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    communities =
      if collection_id do
        Map.get(state.communities, collection_id, [])
      else
        Enum.flat_map(state.communities, fn {_cid, comms} -> comms end)
      end

    communities
    |> maybe_filter_comms_by_level(level_filter)
    |> maybe_filter_comms_by_search(search_filter)
    |> Enum.map(fn c ->
      %{
        id: c.id,
        level: c.level,
        summary: c.summary,
        entity_ids: c.entity_ids,
        entity_count: length(c.entity_ids || []),
        collection_id: c[:collection_id]
      }
    end)
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> then(fn result -> {:reply, result, state} end)
  end

  # === Private Helpers ===

  defp get_server(opts) do
    cond do
      Keyword.has_key?(opts, :pid) -> Keyword.fetch!(opts, :pid)
      Keyword.has_key?(opts, :name) -> Keyword.fetch!(opts, :name)
      true -> __MODULE__
    end
  end

  defp filter_by_collections(entities_map, nil), do: entities_map
  defp filter_by_collections(entities_map, []), do: entities_map

  defp filter_by_collections(entities_map, collection_ids) do
    Map.take(entities_map, collection_ids)
  end

  defp find_related_bfs(_current_ids, visited, 0, _relationships), do: visited
  defp find_related_bfs([], visited, _depth, _relationships), do: visited

  defp find_related_bfs(current_ids, visited, depth, relationships) do
    current_set = MapSet.new(current_ids)

    related_ids =
      relationships
      |> Enum.filter(fn r ->
        MapSet.member?(current_set, r.source_id) or MapSet.member?(current_set, r.target_id)
      end)
      |> Enum.flat_map(fn r -> [r.source_id, r.target_id] end)
      |> Enum.reject(fn id -> MapSet.member?(visited, id) end)
      |> Enum.uniq()

    new_visited = Enum.reduce(related_ids, visited, &MapSet.put(&2, &1))

    find_related_bfs(related_ids, new_visited, depth - 1, relationships)
  end

  # Entity filters
  defp maybe_filter_by_type(entities, nil), do: entities

  defp maybe_filter_by_type(entities, type) do
    Enum.filter(entities, fn e -> e.type == type end)
  end

  defp maybe_filter_by_search(entities, nil), do: entities

  defp maybe_filter_by_search(entities, search) do
    search_lower = String.downcase(search)
    Enum.filter(entities, fn e -> String.contains?(String.downcase(e.name), search_lower) end)
  end

  # Relationship filters
  defp maybe_filter_rels_by_collection(rels, nil), do: rels

  defp maybe_filter_rels_by_collection(rels, entity_ids) do
    Enum.filter(rels, fn r ->
      MapSet.member?(entity_ids, r.source_id) or MapSet.member?(entity_ids, r.target_id)
    end)
  end

  defp maybe_filter_rels_by_type(rels, nil), do: rels

  defp maybe_filter_rels_by_type(rels, type) do
    Enum.filter(rels, fn r -> r.type == type end)
  end

  defp maybe_filter_rels_by_strength(rels, nil), do: rels

  defp maybe_filter_rels_by_strength(rels, strength) do
    Enum.filter(rels, fn r -> r.strength == strength end)
  end

  defp maybe_filter_rels_by_search(rels, nil), do: rels

  defp maybe_filter_rels_by_search(rels, search) do
    search_lower = String.downcase(search)

    Enum.filter(rels, fn r ->
      matches_search?(r.source_name, search_lower) or
        matches_search?(r.target_name, search_lower) or
        matches_search?(r.type, search_lower)
    end)
  end

  defp matches_search?(nil, _search), do: false
  defp matches_search?(value, search), do: String.contains?(String.downcase(value), search)

  # Community filters
  defp maybe_filter_comms_by_level(comms, nil), do: comms

  defp maybe_filter_comms_by_level(comms, level) do
    Enum.filter(comms, fn c -> c.level == level end)
  end

  defp maybe_filter_comms_by_search(comms, nil), do: comms

  defp maybe_filter_comms_by_search(comms, search) do
    search_lower = String.downcase(search)

    Enum.filter(comms, fn c ->
      c.summary && String.contains?(String.downcase(c.summary), search_lower)
    end)
  end
end
