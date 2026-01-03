defmodule Arcana.Graph.FusionSearch do
  @moduledoc """
  Combines vector search and graph-based search using Reciprocal Rank Fusion.

  FusionSearch implements the core GraphRAG retrieval strategy:
  1. Extract entities from the query
  2. Run vector search on document chunks (standard RAG)
  3. Run graph search on the knowledge graph
  4. Merge results using Reciprocal Rank Fusion (RRF)

  ## Reciprocal Rank Fusion

  RRF is a simple but effective method for combining ranked lists:

      score(doc) = Σ 1 / (k + rank(doc, list_i))

  where k is a constant (default: 60) that reduces the impact of high ranks.

  ## Example

      # Build graph from extracted data
      graph = GraphQuery.build_graph(entities, relationships, chunks, communities)

      # Extract entities from query
      {:ok, entities} = Arcana.Graph.EntityExtractor.NER.extract("Tell me about OpenAI", [])

      # Run vector search
      vector_results = Arcana.search(repo, collection, query, top_k: 10)

      # Combine with graph search
      FusionSearch.search(graph, entities, vector_results)

  """

  alias Arcana.Graph.GraphQuery

  @default_k 60
  @default_depth 1
  @default_limit 10

  @doc """
  Merges multiple ranked lists using Reciprocal Rank Fusion.

  ## Options

    - `:k` - RRF constant to reduce high-rank impact (default: 60)

  ## Algorithm

  For each document, computes:

      score = sum(1 / (k + rank)) across all lists

  Higher scores indicate documents that appear in multiple lists
  and/or rank highly in individual lists.
  """
  def reciprocal_rank_fusion(lists, opts \\ []) do
    k = Keyword.get(opts, :k, @default_k)

    # Calculate RRF scores
    scores =
      lists
      |> Enum.reduce(%{}, fn list, acc ->
        accumulate_rrf_scores(list, k, acc)
      end)

    # Sort by score descending
    scores
    |> Map.values()
    |> Enum.sort_by(fn {_item, score} -> score end, :desc)
    |> Enum.map(fn {item, _score} -> item end)
  end

  defp accumulate_rrf_scores(list, k, acc) do
    list
    |> Enum.with_index(1)
    |> Enum.reduce(acc, fn {item, rank}, inner_acc ->
      score = 1.0 / (k + rank)
      update_item_score(inner_acc, item, score)
    end)
  end

  defp update_item_score(scores, item, score) do
    Map.update(scores, item.id, {item, score}, fn {existing_item, existing_score} ->
      {existing_item, existing_score + score}
    end)
  end

  @doc """
  Searches the knowledge graph based on recognized entities.

  Finds entities in the graph matching the provided extracted entities,
  then traverses relationships to collect connected chunks.

  ## Options

    - `:depth` - How many hops to traverse (default: 1)

  """
  def graph_search(graph, entities, opts \\ []) do
    depth = Keyword.get(opts, :depth, @default_depth)

    # Find matching entities in the graph
    entity_ids =
      entities
      |> Enum.flat_map(fn extracted ->
        matches = GraphQuery.find_entities_by_name(graph, extracted.name, fuzzy: false)
        Enum.map(matches, & &1.id)
      end)
      |> Enum.uniq()

    if entity_ids == [] do
      []
    else
      # Traverse to find related entities
      related_ids =
        entity_ids
        |> Enum.flat_map(fn id ->
          related = GraphQuery.traverse(graph, id, depth: depth)
          [id | Enum.map(related, & &1.id)]
        end)
        |> Enum.uniq()

      # Get chunks connected to all related entities
      GraphQuery.get_chunks_for_entities(graph, related_ids)
    end
  end

  @doc """
  Combines vector search results with graph search using RRF.

  Takes pre-computed vector search results and entities extracted from
  the query, runs graph search, then merges both result sets.

  ## Options

    - `:depth` - Graph traversal depth (default: 1)
    - `:limit` - Maximum results to return (default: 10)
    - `:k` - RRF constant (default: 60)

  """
  def search(graph, entities, vector_results, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    depth = Keyword.get(opts, :depth, @default_depth)
    k = Keyword.get(opts, :k, @default_k)

    # Run graph search
    graph_results = graph_search(graph, entities, depth: depth)

    # Merge using RRF
    reciprocal_rank_fusion([vector_results, graph_results], k: k)
    |> Enum.take(limit)
  end
end
