defmodule Arcana.Graph do
  @moduledoc """
  GraphRAG (Graph-enhanced Retrieval Augmented Generation) for Arcana.

  This module provides the public API for GraphRAG functionality:
  - Building knowledge graphs from documents
  - Graph-based search and retrieval
  - Fusion search combining vector and graph results
  - Community summaries for global context

  ## Configuration

  GraphRAG is disabled by default. Enable it in your config:

      config :arcana,
        graph: [
          enabled: true,
          community_levels: 5,
          resolution: 1.0
        ]

  Or enable per-call:

      Arcana.ingest(text, repo: MyApp.Repo, graph: true)
      Arcana.search(query, repo: MyApp.Repo, graph: true)

  ## Usage

      # Build a graph from chunks
      {:ok, graph_data} = Arcana.Graph.build(chunks,
        entity_extractor: &MyApp.extract_entities/2,
        relationship_extractor: &MyApp.extract_relationships/3
      )

      # Convert to queryable format
      graph = Arcana.Graph.to_query_graph(graph_data, chunks)

      # Search the graph
      results = Arcana.Graph.search(graph, entities, depth: 2)

      # Fusion search combining vector and graph
      results = Arcana.Graph.fusion_search(graph, entities, vector_results)

  ## Components

  GraphRAG consists of several modules:

    * `Arcana.Graph.EntityExtractor` - Behaviour for entity extraction
    * `Arcana.Graph.EntityExtractor.NER` - Built-in NER implementation (default)
    * `Arcana.Graph.RelationshipExtractor` - Extracts relationships using LLM
    * `Arcana.Graph.CommunityDetector` - Detects communities with Leiden algorithm
    * `Arcana.Graph.CommunitySummarizer` - Generates LLM summaries for communities
    * `Arcana.Graph.GraphQuery` - Queries the knowledge graph
    * `Arcana.Graph.FusionSearch` - Combines vector and graph search with RRF
    * `Arcana.Graph.GraphBuilder` - Orchestrates graph construction

  """

  alias Arcana.Graph.{FusionSearch, GraphBuilder, GraphQuery}

  @default_config %{
    enabled: false,
    community_levels: 5,
    resolution: 1.0
  }

  @doc """
  Returns the current GraphRAG configuration.

  ## Example

      Arcana.Graph.config()
      # => %{enabled: false, community_levels: 5, resolution: 1.0}

  """
  @spec config() :: map()
  def config do
    app_config = Application.get_env(:arcana, :graph, [])

    @default_config
    |> Map.merge(Map.new(app_config))
  end

  @doc """
  Returns whether GraphRAG is enabled globally.

  Check this before performing graph operations:

      if Arcana.Graph.enabled?() do
        # Build graph during ingest
      end

  """
  @spec enabled?() :: boolean()
  def enabled? do
    config().enabled
  end

  @doc """
  Builds graph data from document chunks.

  Delegates to `Arcana.Graph.GraphBuilder.build/2`.

  ## Options

    - `:entity_extractor` - Function to extract entities from text
    - `:relationship_extractor` - Function to extract relationships

  ## Example

      {:ok, graph_data} = Arcana.Graph.build(chunks,
        entity_extractor: fn text, _opts ->
          Arcana.Graph.EntityExtractor.NER.extract(text, [])
        end,
        relationship_extractor: fn text, entities, _opts ->
          Arcana.Graph.RelationshipExtractor.extract(text, entities, my_llm)
        end
      )

  """
  @spec build([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def build(chunks, opts) do
    GraphBuilder.build(chunks, opts)
  end

  @doc """
  Converts builder output to queryable graph format.

  Delegates to `Arcana.Graph.GraphBuilder.to_query_graph/2`.
  """
  @spec to_query_graph(map(), [map()]) :: GraphQuery.graph()
  def to_query_graph(graph_data, chunks) do
    GraphBuilder.to_query_graph(graph_data, chunks)
  end

  @doc """
  Searches the knowledge graph for relevant chunks.

  Finds entities matching the query, traverses relationships,
  and returns connected chunks.

  ## Options

    - `:depth` - How many hops to traverse (default: 1)

  ## Example

      entities = [%{name: "OpenAI", type: :organization}]
      results = Arcana.Graph.search(graph, entities, depth: 2)

  """
  @spec search(GraphQuery.graph(), [map()], keyword()) :: [map()]
  def search(graph, entities, opts \\ []) do
    FusionSearch.graph_search(graph, entities, opts)
  end

  @doc """
  Combines vector search and graph search using Reciprocal Rank Fusion.

  This is the primary retrieval method for GraphRAG, merging results
  from both vector similarity and knowledge graph traversal.

  ## Options

    - `:depth` - Graph traversal depth (default: 1)
    - `:limit` - Maximum results to return (default: 10)
    - `:k` - RRF constant (default: 60)

  ## Example

      # Run vector search separately
      {:ok, vector_results} = Arcana.search(query, repo: MyApp.Repo)

      # Extract entities from query
      {:ok, entities} = Arcana.Graph.EntityExtractor.NER.extract(query, [])

      # Combine with graph search
      results = Arcana.Graph.fusion_search(graph, entities, vector_results)

  """
  @spec fusion_search(GraphQuery.graph(), [map()], [map()], keyword()) :: [map()]
  def fusion_search(graph, entities, vector_results, opts \\ []) do
    FusionSearch.search(graph, entities, vector_results, opts)
  end

  @doc """
  Gets community summaries from the graph.

  Community summaries provide high-level context about clusters
  of related entities, useful for global queries.

  ## Options

    - `:level` - Filter by hierarchy level (0 = finest)
    - `:entity_id` - Filter by communities containing entity

  ## Example

      # Get all top-level summaries
      summaries = Arcana.Graph.community_summaries(graph, level: 0)

  """
  @spec community_summaries(GraphQuery.graph(), keyword()) :: [map()]
  def community_summaries(graph, opts \\ []) do
    GraphQuery.get_community_summaries(graph, opts)
  end

  @doc """
  Finds entities in the graph by name.

  ## Options

    - `:fuzzy` - Enable fuzzy matching (default: false)

  """
  @spec find_entities(GraphQuery.graph(), String.t(), keyword()) :: [map()]
  def find_entities(graph, name, opts \\ []) do
    GraphQuery.find_entities_by_name(graph, name, opts)
  end

  @doc """
  Traverses the graph from a starting entity.

  ## Options

    - `:depth` - Maximum traversal depth (default: 1)

  """
  @spec traverse(GraphQuery.graph(), String.t(), keyword()) :: [map()]
  def traverse(graph, entity_id, opts \\ []) do
    GraphQuery.traverse(graph, entity_id, opts)
  end
end
