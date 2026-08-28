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

  import Ecto.Query

  @behaviour Arcana.Graph.GraphStore

  alias Arcana.Graph.{EntityName, Relationship}
  alias Arcana.RetrievalScope

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
  def persist_relationships(chunk_id, relationships, entity_id_map, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_relationships, chunk_id, relationships, entity_id_map})
  end

  @impl Arcana.Graph.GraphStore
  def persist_mentions(mentions, entity_id_map, opts) do
    server = get_server(opts)
    GenServer.call(server, {:persist_mentions, mentions, entity_id_map})
  end

  @impl Arcana.Graph.GraphStore
  def search(entity_names, collection_ids, opts) do
    server = get_server(opts)

    GenServer.call(
      server,
      {:search, entity_names, collection_ids, visible_chunk_ids(server, opts)}
    )
  end

  @impl Arcana.Graph.GraphStore
  def search_by_embedding(_query_embedding, _collection_ids, _opts), do: []

  @impl Arcana.Graph.GraphStore
  def find_entities(collection_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:find_entities, collection_id, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def find_related_entities(entity_id, depth, opts) do
    server = get_server(opts)

    GenServer.call(
      server,
      {:find_related_entities, entity_id, depth, visible_chunk_ids(server, opts)}
    )
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

    GenServer.call(
      server,
      {:delete_by_chunks, chunk_ids, visible_chunk_ids(server, opts),
       MapSet.new(Keyword.get(opts, :published_chunk_ids, []))}
    )
  end

  @impl Arcana.Graph.GraphStore
  def delete_by_collection(collection_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:delete_by_collection, collection_id})
  end

  @impl Arcana.Graph.GraphStore
  def sweep_orphans(collection_id, opts) do
    with_write_lock(collection_id, opts, fn ->
      server = get_server(opts)
      GenServer.call(server, {:sweep_orphans, collection_id})
    end)
  end

  @impl Arcana.Graph.GraphStore
  def with_write_lock(collection_id, opts, fun) when is_function(fun, 0) do
    server = get_server(opts)
    server_pid = server_pid!(server)
    resource = {__MODULE__, server_pid, collection_id}
    :global.trans({resource, self()}, fun, [node(server_pid)])
  end

  @impl Arcana.Graph.GraphStore
  def get_entity(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_entity, entity_id, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def get_relationships(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_relationships, entity_id, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def get_relationship(relationship_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_relationship, relationship_id, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def get_mentions(entity_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_mentions, entity_id, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def get_community(community_id, opts) do
    server = get_server(opts)
    GenServer.call(server, {:get_community, community_id})
  end

  @impl Arcana.Graph.GraphStore
  def list_entities(opts) do
    server = get_server(opts)
    GenServer.call(server, {:list_entities, opts, visible_chunk_ids(server, opts)})
  end

  @impl Arcana.Graph.GraphStore
  def list_relationships(opts) do
    server = get_server(opts)
    GenServer.call(server, {:list_relationships, opts, visible_chunk_ids(server, opts)})
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
    # Deduplicate on the normalized name (first-seen entity wins, keeping
    # its original name for display)
    unique_entities =
      entities
      |> Enum.map(fn entity -> {EntityName.normalize(entity.name), entity} end)
      |> Enum.reject(fn {key, _entity} -> is_nil(key) or key == "" end)
      |> Enum.uniq_by(fn {key, _entity} -> key end)

    # Get existing entities for this collection
    existing = Map.get(state.entities, collection_id, [])
    existing_by_key = Map.new(existing, fn e -> {EntityName.normalize(e.name), e} end)

    # Upsert and build normalized-name -> id map
    {new_entities, id_map} =
      Enum.reduce(unique_entities, {existing, %{}}, fn {key, entity}, {ents, ids} ->
        case Map.get(existing_by_key, key) do
          nil ->
            # Insert new entity
            new_entity =
              Map.merge(entity, %{
                id: Ecto.UUID.generate(),
                collection_id: collection_id
              })

            {[new_entity | ents], Map.put(ids, key, new_entity.id)}

          existing_entity ->
            # Return existing
            {ents, Map.put(ids, key, existing_entity.id)}
        end
      end)

    new_state = put_in(state.entities[collection_id], new_entities)
    {:reply, {:ok, id_map}, new_state}
  end

  @impl GenServer
  def handle_call(
        {:persist_relationships, chunk_id, relationships, entity_id_map},
        _from,
        state
      ) do
    valid_relationships =
      relationships
      |> Enum.map(fn rel ->
        {EntityName.normalize(rel.source), EntityName.normalize(rel.target), rel}
      end)
      |> Enum.filter(fn {source_key, target_key, _rel} ->
        Map.has_key?(entity_id_map, source_key) and Map.has_key?(entity_id_map, target_key)
      end)
      |> Enum.map(fn {source_key, target_key, rel} ->
        attrs = %{
          source_id: entity_id_map[source_key],
          target_id: entity_id_map[target_key],
          type: rel.type,
          description: rel[:description],
          strength: rel[:strength],
          metadata: Relationship.normalized_metadata(rel[:metadata])
        }

        Map.put(attrs, :fingerprint, Relationship.fingerprint(attrs))
      end)

    new_relationships =
      Enum.reduce(valid_relationships, state.relationships, fn relationship, stored ->
        case Enum.find_index(stored, &(&1.fingerprint == relationship.fingerprint)) do
          nil ->
            [
              relationship
              |> Map.put(:id, Ecto.UUID.generate())
              |> Map.put(:evidence, MapSet.new([chunk_id]))
              | stored
            ]

          index ->
            List.update_at(stored, index, fn existing ->
              %{existing | evidence: MapSet.put(existing.evidence, chunk_id)}
            end)
        end
      end)

    new_state = %{state | relationships: new_relationships}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call(:publication_candidates, _from, state) do
    chunk_ids =
      state.mentions
      |> Enum.map(& &1.chunk_id)
      |> Enum.concat(
        Enum.flat_map(state.relationships, fn relationship ->
          MapSet.to_list(relationship.evidence)
        end)
      )
      |> Enum.uniq()

    {:reply, chunk_ids, state}
  end

  @impl GenServer
  def handle_call({:persist_mentions, mentions, entity_id_map}, _from, state) do
    existing_pairs = MapSet.new(state.mentions, fn m -> {m.entity_id, m.chunk_id} end)

    valid_mentions =
      mentions
      |> Enum.map(fn m -> {EntityName.normalize(m.entity_name), m} end)
      |> Enum.filter(fn {key, _m} -> Map.has_key?(entity_id_map, key) end)
      |> Enum.map(fn {key, m} ->
        %{
          id: Ecto.UUID.generate(),
          entity_id: entity_id_map[key],
          chunk_id: m.chunk_id,
          span_start: m[:span_start],
          span_end: m[:span_end]
        }
      end)
      |> Enum.uniq_by(fn m -> {m.entity_id, m.chunk_id} end)
      |> Enum.reject(fn m -> MapSet.member?(existing_pairs, {m.entity_id, m.chunk_id}) end)

    new_state = %{state | mentions: state.mentions ++ valid_mentions}
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_call({:search, entity_names, collection_ids, visible_chunks}, _from, state) do
    # Match on the normalized name: persistence collapses variants onto
    # one entity keeping its first-seen display name, so matching raw
    # names here would miss a stored "Two_Year_Limited_Warranty" for a
    # query that asks for "two year limited warranty".
    wanted = MapSet.new(entity_names, &EntityName.normalize/1)

    entity_ids =
      state.entities
      |> filter_by_collections(collection_ids)
      |> Enum.flat_map(fn {_cid, entities} -> entities end)
      |> Enum.filter(fn e -> MapSet.member?(wanted, EntityName.normalize(e.name)) end)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if MapSet.size(entity_ids) == 0 do
      {:reply, [], state}
    else
      # Find chunks with mentions of these entities
      chunk_scores =
        state.mentions
        |> Enum.filter(fn m ->
          MapSet.member?(entity_ids, m.entity_id) and visible_chunk?(m.chunk_id, visible_chunks)
        end)
        |> Enum.group_by(& &1.chunk_id)
        |> Enum.map(fn {chunk_id, mentions} ->
          %{chunk_id: chunk_id, score: length(mentions) * 0.1}
        end)
        |> Enum.sort_by(& &1.score, :desc)

      {:reply, chunk_scores, state}
    end
  end

  @impl GenServer
  def handle_call({:find_entities, collection_id, visible_chunks}, _from, state) do
    entities =
      state.entities
      |> Map.get(collection_id, [])
      |> Enum.filter(&visible_entity?(&1.id, state.mentions, visible_chunks))
      |> Enum.map(fn e ->
        %{id: e.id, name: e.name, type: e.type, description: e[:description]}
      end)

    {:reply, entities, state}
  end

  @impl GenServer
  def handle_call({:find_related_entities, entity_id, depth, visible_chunks}, _from, state) do
    # BFS traversal
    relationships = Enum.filter(state.relationships, &visible_relationship?(&1, visible_chunks))
    visited = find_related_bfs([entity_id], MapSet.new([entity_id]), depth, relationships)

    entities =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Enum.filter(fn e ->
        MapSet.member?(visited, e.id) and visible_entity?(e.id, state.mentions, visible_chunks)
      end)
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
      |> Enum.reject(& &1[:dirty])
      |> Enum.map(fn c ->
        %{id: c.id, level: c.level, summary: c.summary, entity_ids: c.entity_ids}
      end)

    {:reply, communities, state}
  end

  @impl GenServer
  def handle_call(
        {:delete_by_chunks, chunk_ids, visible_chunks, published_chunk_ids},
        _from,
        state
      ) do
    chunk_id_set = MapSet.new(chunk_ids)
    visible_before_delete = include_published_snapshot(visible_chunks, published_chunk_ids)

    unpublished_endpoints =
      state.relationships
      |> Enum.filter(fn relationship ->
        Enum.any?(relationship.evidence, &visible_chunk?(&1, visible_before_delete)) and
          not MapSet.disjoint?(relationship.evidence, chunk_id_set) and
          relationship.evidence
          |> MapSet.difference(chunk_id_set)
          |> Enum.all?(&(not visible_chunk?(&1, visible_chunks)))
      end)
      |> Enum.flat_map(&[&1.source_id, &1.target_id])
      |> MapSet.new()

    new_relationships =
      Enum.flat_map(state.relationships, fn relationship ->
        evidence = MapSet.difference(relationship.evidence, chunk_id_set)
        if MapSet.size(evidence) == 0, do: [], else: [%{relationship | evidence: evidence}]
      end)

    # Remove mentions for these chunks
    new_mentions =
      Enum.reject(state.mentions, fn m -> MapSet.member?(chunk_id_set, m.chunk_id) end)

    # Only the collections these chunks touched: a delete in one tenant must
    # not sweep another tenant's entities, which is what the Ecto store does.
    affected =
      state.mentions
      |> Enum.filter(&MapSet.member?(chunk_id_set, &1.chunk_id))
      |> Enum.map(& &1.entity_id)
      |> MapSet.new()
      |> MapSet.union(unpublished_endpoints)

    affected_collections =
      state.entities
      |> Enum.filter(fn {_cid, entities} ->
        Enum.any?(entities, &MapSet.member?(affected, &1.id))
      end)
      |> Enum.map(fn {cid, _entities} -> cid end)

    # Sweeping through the same helper the sweep_orphans call uses, rather
    # than inline: the inline version dropped the orphans but never marked
    # the communities holding them dirty, so the two backends disagreed
    # about the same delete and stale summaries survived until the next
    # full summarize pass.
    new_state =
      Enum.reduce(
        affected_collections,
        %{state | mentions: new_mentions, relationships: new_relationships},
        &sweep_collection(&2, &1)
      )
      |> mark_relationship_communities_dirty(unpublished_endpoints)

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
  def handle_call({:sweep_orphans, collection_id}, _from, state) do
    {:reply, :ok, sweep_collection(state, collection_id)}
  end

  @impl GenServer
  def handle_call({:get_entity, entity_id, visible_chunks}, _from, state) do
    entity =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Enum.find(fn e ->
        e.id == entity_id and visible_entity?(e.id, state.mentions, visible_chunks)
      end)

    result =
      case entity do
        nil -> {:error, :not_found}
        e -> {:ok, e}
      end

    {:reply, result, state}
  end

  @impl GenServer
  def handle_call({:get_relationships, entity_id, visible_chunks}, _from, state) do
    # Build entity lookup for names
    entity_by_id =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Map.new(fn e -> {e.id, e} end)

    relationships =
      state.relationships
      |> Enum.filter(fn relationship ->
        visible_relationship?(relationship, visible_chunks) and
          (relationship.source_id == entity_id or relationship.target_id == entity_id)
      end)
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
  def handle_call({:get_relationship, relationship_id, visible_chunks}, _from, state) do
    # Build entity lookup for names
    entity_by_id =
      state.entities
      |> Enum.flat_map(fn {_cid, ents} -> ents end)
      |> Map.new(fn e -> {e.id, e} end)

    relationship =
      Enum.find(state.relationships, fn r ->
        r.id == relationship_id and visible_relationship?(r, visible_chunks)
      end)

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
  def handle_call({:get_mentions, entity_id, visible_chunks}, _from, state) do
    # Note: In memory backend, we don't have chunk text - just return mention structure
    mentions =
      state.mentions
      |> Enum.filter(fn mention ->
        mention.entity_id == entity_id and visible_chunk?(mention.chunk_id, visible_chunks)
      end)
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
  def handle_call({:list_entities, opts, visible_chunks}, _from, state) do
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
      |> Enum.filter(&visible_entity?(&1.id, state.mentions, visible_chunks))

    # Count mentions per entity
    mention_counts =
      state.mentions
      |> Enum.filter(&visible_chunk?(&1.chunk_id, visible_chunks))
      |> Enum.group_by(& &1.entity_id)
      |> Map.new(fn {eid, mentions} -> {eid, length(mentions)} end)

    # Count relationships per entity
    relationship_counts =
      state.relationships
      |> Enum.filter(&visible_relationship?(&1, visible_chunks))
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
  def handle_call({:list_relationships, opts, visible_chunks}, _from, state) do
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
      |> Enum.filter(&visible_relationship?(&1, visible_chunks))
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

  defp server_pid!(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> pid
      nil -> raise ArgumentError, "memory graph store #{inspect(server)} is not running"
    end
  end

  defp visible_chunk_ids(server, opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} ->
        candidates = GenServer.call(server, :publication_candidates)

        if candidates == [] do
          MapSet.new()
        else
          repo.all(
            from([chunk: c] in RetrievalScope.chunks(),
              where: c.id in ^candidates,
              select: c.id
            )
          )
          |> MapSet.new()
        end

      :error ->
        :all
    end
  end

  defp visible_chunk?(_chunk_id, :all), do: true
  defp visible_chunk?(chunk_id, visible_chunks), do: MapSet.member?(visible_chunks, chunk_id)

  defp include_published_snapshot(:all, _published_chunk_ids), do: :all

  defp include_published_snapshot(visible_chunks, published_chunk_ids) do
    MapSet.union(visible_chunks, published_chunk_ids)
  end

  defp visible_entity?(entity_id, mentions, visible_chunks) do
    if visible_chunks == :all do
      true
    else
      Enum.any?(mentions, fn mention ->
        mention.entity_id == entity_id and visible_chunk?(mention.chunk_id, visible_chunks)
      end)
    end
  end

  defp visible_relationship?(relationship, visible_chunks) do
    Enum.any?(relationship.evidence, &visible_chunk?(&1, visible_chunks))
  end

  # nil means unscoped; [] means the caller named collections that resolved
  # to nothing and must match nothing, never fall back to everything.
  defp filter_by_collections(entities_map, nil), do: entities_map

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

  # Drops the swept ids from entity_ids too, so entity_count stops
  # counting entities that no longer exist, and bumps updated_at the way
  # the Ecto backend does.
  defp mark_overlapping_dirty(communities, orphaned_ids) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Enum.map(communities, fn community ->
      entity_ids = community.entity_ids || []

      if Enum.any?(entity_ids, &MapSet.member?(orphaned_ids, &1)) do
        community
        |> Map.put(:dirty, true)
        |> Map.put(:updated_at, now)
        |> Map.put(:entity_ids, Enum.reject(entity_ids, &MapSet.member?(orphaned_ids, &1)))
      else
        community
      end
    end)
  end

  defp mark_relationship_communities_dirty(state, endpoint_ids) do
    if MapSet.size(endpoint_ids) == 0 do
      state
    else
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      communities =
        Map.new(state.communities, fn {collection_id, communities} ->
          updated =
            Enum.map(communities, &maybe_dirty_relationship_community(&1, endpoint_ids, now))

          {collection_id, updated}
        end)

      %{state | communities: communities}
    end
  end

  defp maybe_dirty_relationship_community(community, endpoint_ids, now) do
    if Enum.any?(community.entity_ids || [], &MapSet.member?(endpoint_ids, &1)) do
      community
      |> Map.put(:dirty, true)
      |> Map.put(:updated_at, now)
    else
      community
    end
  end

  # Drops entities in the collection that no mention points at any more,
  # along with their relationships, and marks every community that held one
  # dirty so it gets re-summarized. Shared with the delete_by_chunks path,
  # which sweeps each collection its chunks touched.
  defp sweep_collection(state, collection_id) do
    mentioned_ids = MapSet.new(state.mentions, & &1.entity_id)

    {kept, orphaned} =
      state.entities
      |> Map.get(collection_id, [])
      |> Enum.split_with(fn e -> MapSet.member?(mentioned_ids, e.id) end)

    orphaned_ids = MapSet.new(orphaned, & &1.id)

    new_relationships =
      Enum.reject(state.relationships, fn r ->
        MapSet.member?(orphaned_ids, r.source_id) or MapSet.member?(orphaned_ids, r.target_id)
      end)

    new_communities =
      Map.update(
        state.communities,
        collection_id,
        [],
        &mark_overlapping_dirty(&1, orphaned_ids)
      )

    %{
      state
      | entities: Map.put(state.entities, collection_id, kept),
        relationships: new_relationships,
        communities: new_communities
    }
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
