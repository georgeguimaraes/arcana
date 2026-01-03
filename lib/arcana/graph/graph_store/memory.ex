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
end
