defmodule Arcana.Graph.GraphQuery do
  @moduledoc """
  Queries the knowledge graph for entities, relationships, and community summaries.

  This module provides efficient graph traversal and lookup operations for
  GraphRAG workflows. It works with in-memory graph structures built from
  entities, relationships, chunks, and community summaries.

  ## Graph Structure

  The graph is represented as a map with indexed lookups for efficient querying:

      %{
        entities: %{id => entity},
        relationships: [relationship],
        chunks: [chunk],
        communities: [community],
        adjacency: %{entity_id => [neighbor_ids]},
        entity_chunks: %{entity_id => [chunk_ids]}
      }

  ## Example

      graph = GraphQuery.build_graph(entities, relationships, chunks, communities)

      # Find entities by name
      GraphQuery.find_entities_by_name(graph, "OpenAI")

      # Traverse the graph
      GraphQuery.traverse(graph, "entity_id", depth: 2)

      # Get relevant chunks
      GraphQuery.get_chunks_for_entities(graph, ["id1", "id2"])

  """

  @type entity :: %{
          id: String.t(),
          name: String.t(),
          type: atom(),
          embedding: [float()] | nil
        }

  @type relationship :: %{
          source_id: String.t(),
          target_id: String.t(),
          type: String.t()
        }

  @type chunk :: %{
          id: String.t(),
          entity_ids: [String.t()],
          content: String.t()
        }

  @type community :: %{
          id: String.t(),
          level: non_neg_integer(),
          entity_ids: [String.t()],
          summary: String.t()
        }

  @type graph :: %{
          entities: %{String.t() => entity()},
          relationships: [relationship()],
          chunks: [chunk()],
          communities: [community()],
          adjacency: %{String.t() => [String.t()]},
          entity_chunks: %{String.t() => [String.t()]}
        }

  @doc """
  Builds a graph structure from entities, relationships, chunks, and communities.

  Creates indexed lookups for efficient querying:
  - Entity lookup by ID
  - Adjacency list for graph traversal
  - Entity-to-chunk mapping for retrieval
  """
  @spec build_graph([entity()], [relationship()], [chunk()], [community()]) :: graph()
  def build_graph(entities, relationships, chunks, communities) do
    entity_map = Map.new(entities, fn e -> {e.id, e} end)
    adjacency = build_adjacency(relationships)
    entity_chunks = build_entity_chunks(chunks)

    %{
      entities: entity_map,
      relationships: relationships,
      chunks: chunks,
      communities: communities,
      adjacency: adjacency,
      entity_chunks: entity_chunks
    }
  end

  @doc """
  Finds entities by name with optional fuzzy matching.

  ## Options

    - `:fuzzy` - When true, matches if entity name contains the query (default: false)

  ## Examples

      # Exact match (case-insensitive)
      GraphQuery.find_entities_by_name(graph, "OpenAI")

      # Fuzzy match
      GraphQuery.find_entities_by_name(graph, "Open", fuzzy: true)

  """
  @spec find_entities_by_name(graph(), String.t(), keyword()) :: [entity()]
  def find_entities_by_name(graph, query, opts \\ []) do
    fuzzy = Keyword.get(opts, :fuzzy, false)
    query_lower = String.downcase(query)

    graph.entities
    |> Map.values()
    |> Enum.filter(fn entity ->
      name_lower = String.downcase(entity.name)

      if fuzzy do
        String.contains?(name_lower, query_lower)
      else
        name_lower == query_lower
      end
    end)
  end

  @doc """
  Finds entities similar to a query embedding using cosine similarity.

  ## Options

    - `:top_k` - Maximum number of results to return (default: 10)
    - `:min_similarity` - Minimum cosine similarity threshold (default: 0.0)

  """
  @spec find_entities_by_embedding(graph(), [float()], keyword()) :: [entity()]
  def find_entities_by_embedding(graph, query_embedding, opts \\ []) do
    top_k = Keyword.get(opts, :top_k, 10)
    min_similarity = Keyword.get(opts, :min_similarity, 0.0)

    graph.entities
    |> Map.values()
    |> Enum.filter(fn entity -> entity[:embedding] != nil end)
    |> Enum.map(fn entity ->
      similarity = cosine_similarity(query_embedding, entity.embedding)
      {entity, similarity}
    end)
    |> Enum.filter(fn {_entity, similarity} -> similarity >= min_similarity end)
    |> Enum.sort_by(fn {_entity, similarity} -> similarity end, :desc)
    |> Enum.take(top_k)
    |> Enum.map(fn {entity, _similarity} -> entity end)
  end

  @doc """
  Traverses the graph from a starting entity up to the specified depth.

  Returns all entities reachable within the given number of hops.
  Does not include the starting entity in results.

  ## Options

    - `:depth` - Maximum traversal depth (default: 1)

  """
  @spec traverse(graph(), String.t(), keyword()) :: [entity()]
  def traverse(graph, entity_id, opts \\ []) do
    depth = Keyword.get(opts, :depth, 1)

    do_traverse(graph, MapSet.new([entity_id]), MapSet.new([entity_id]), depth)
    |> MapSet.delete(entity_id)
    |> Enum.map(fn id -> Map.get(graph.entities, id) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets all chunks connected to a set of entities.

  Returns unique chunks that contain at least one of the specified entities.
  """
  @spec get_chunks_for_entities(graph(), [String.t()]) :: [chunk()]
  def get_chunks_for_entities(graph, entity_ids) do
    chunk_ids =
      entity_ids
      |> Enum.flat_map(fn id -> Map.get(graph.entity_chunks, id, []) end)
      |> MapSet.new()

    chunk_map = Map.new(graph.chunks, fn c -> {c.id, c} end)

    chunk_ids
    |> Enum.map(fn id -> Map.get(chunk_map, id) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets community summaries with optional filtering.

  ## Options

    - `:level` - Filter by hierarchy level
    - `:entity_id` - Filter by communities containing a specific entity

  """
  @spec get_community_summaries(graph(), keyword()) :: [community()]
  def get_community_summaries(graph, opts \\ []) do
    level = Keyword.get(opts, :level)
    entity_id = Keyword.get(opts, :entity_id)

    graph.communities
    |> maybe_filter_by_level(level)
    |> maybe_filter_by_entity(entity_id)
  end

  # Private functions

  defp build_adjacency(relationships) do
    Enum.reduce(relationships, %{}, fn rel, acc ->
      acc
      |> Map.update(rel.source_id, [rel.target_id], &[rel.target_id | &1])
      |> Map.update(rel.target_id, [rel.source_id], &[rel.source_id | &1])
    end)
  end

  defp build_entity_chunks(chunks) do
    Enum.reduce(chunks, %{}, fn chunk, acc ->
      Enum.reduce(chunk.entity_ids, acc, fn entity_id, inner_acc ->
        Map.update(inner_acc, entity_id, [chunk.id], &[chunk.id | &1])
      end)
    end)
  end

  defp do_traverse(_graph, visited, _frontier, 0), do: visited

  defp do_traverse(graph, visited, frontier, depth) do
    new_neighbors =
      frontier
      |> Enum.flat_map(fn id -> Map.get(graph.adjacency, id, []) end)
      |> MapSet.new()
      |> MapSet.difference(visited)

    if MapSet.size(new_neighbors) == 0 do
      visited
    else
      new_visited = MapSet.union(visited, new_neighbors)
      do_traverse(graph, new_visited, new_neighbors, depth - 1)
    end
  end

  defp cosine_similarity(a, b) when length(a) == length(b) do
    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    norm_a = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    norm_b = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if norm_a == 0.0 or norm_b == 0.0 do
      0.0
    else
      dot / (norm_a * norm_b)
    end
  end

  defp cosine_similarity(_a, _b), do: 0.0

  defp maybe_filter_by_level(communities, nil), do: communities

  defp maybe_filter_by_level(communities, level) do
    Enum.filter(communities, fn c -> c.level == level end)
  end

  defp maybe_filter_by_entity(communities, nil), do: communities

  defp maybe_filter_by_entity(communities, entity_id) do
    Enum.filter(communities, fn c -> entity_id in c.entity_ids end)
  end
end
