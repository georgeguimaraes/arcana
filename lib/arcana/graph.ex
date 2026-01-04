defmodule Arcana.Graph do
  @moduledoc """
  GraphRAG (Graph-enhanced Retrieval Augmented Generation) for Arcana.

  This module provides the public API for GraphRAG functionality:
  - Building knowledge graphs from documents
  - Graph-based search and retrieval
  - Fusion search combining vector and graph results
  - Community summaries for global context

  ## Installation

  GraphRAG is optional and requires separate installation:

      $ mix arcana.graph.install
      $ mix ecto.migrate

  Add the NER serving to your supervision tree:

      children = [
        MyApp.Repo,
        Arcana.Embedder.Local,
        Arcana.Graph.NERServing  # For entity extraction
      ]

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
    * `Arcana.Graph.RelationshipExtractor` - Behaviour for relationship extraction
    * `Arcana.Graph.RelationshipExtractor.LLM` - Built-in LLM implementation (default)
    * `Arcana.Graph.RelationshipExtractor.Cooccurrence` - Local co-occurrence (no LLM)
    * `Arcana.Graph.CommunityDetector` - Behaviour for community detection
    * `Arcana.Graph.CommunityDetector.Leiden` - Built-in Leiden implementation (default)
    * `Arcana.Graph.CommunitySummarizer` - Behaviour for community summarization
    * `Arcana.Graph.CommunitySummarizer.LLM` - Built-in LLM implementation (default)
    * `Arcana.Graph.GraphQuery` - Queries the knowledge graph
    * `Arcana.Graph.FusionSearch` - Combines vector and graph search with RRF
    * `Arcana.Graph.GraphBuilder` - Orchestrates graph construction

  ## Custom Implementations

  All core extractors and detectors support the behaviour pattern for extensibility:

      # Custom entity extractor
      config :arcana, :graph,
        entity_extractor: {MyApp.SpacyExtractor, endpoint: "http://localhost:5000"}

      # Custom relationship extractor
      config :arcana, :graph,
        relationship_extractor: {MyApp.PatternExtractor, patterns: [...]}

      # Custom community detector
      config :arcana, :graph,
        community_detector: {MyApp.LouvainDetector, resolution: 0.5}

      # Custom community summarizer
      config :arcana, :graph,
        community_summarizer: {MyApp.ExtractiveSum, max_sentences: 3}

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
  def build(chunks, opts) do
    GraphBuilder.build(chunks, opts)
  end

  @doc """
  Converts builder output to queryable graph format.

  Delegates to `Arcana.Graph.GraphBuilder.to_query_graph/2`.
  """
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
  def community_summaries(graph, opts \\ []) do
    GraphQuery.get_community_summaries(graph, opts)
  end

  @doc """
  Finds entities in the graph by name.

  ## Options

    - `:fuzzy` - Enable fuzzy matching (default: false)

  """
  def find_entities(graph, name, opts \\ []) do
    GraphQuery.find_entities_by_name(graph, name, opts)
  end

  @doc """
  Traverses the graph from a starting entity.

  ## Options

    - `:depth` - Maximum traversal depth (default: 1)

  """
  def traverse(graph, entity_id, opts \\ []) do
    GraphQuery.traverse(graph, entity_id, opts)
  end

  # === Graph Building for Ingest ===

  alias Arcana.Graph.{EntityExtractor, GraphExtractor, GraphStore, RelationshipExtractor}

  @doc """
  Builds and persists graph data from chunk records during ingest.

  Processes chunks incrementally, persisting after each chunk so progress
  is saved continuously. Accepts an optional `:progress` callback that
  receives `{current_chunk, total_chunks}` after each chunk is processed.

  ## Options

    * `:progress` - Callback function `fn current, total -> ... end` called after each chunk

  ## Examples

      # With progress logging
      Arcana.Graph.build_and_persist(chunks, collection, repo,
        progress: fn current, total ->
          IO.puts("Processed chunk \#{current}/\#{total}")
        end
      )

  """
  @default_concurrency 3

  def build_and_persist(chunk_records, collection, repo, opts) do
    collection_name = if is_binary(collection), do: collection, else: collection.name
    collection_id = if is_binary(collection), do: collection, else: collection.id
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)
    total_chunks = length(chunk_records)

    :telemetry.span(
      [:arcana, :graph, :build],
      %{chunk_count: total_chunks, collection: collection_name},
      fn ->
        graph_config = config()
        extractor = resolve_extractor(opts, graph_config)

        # Process and persist each chunk incrementally
        {entity_id_map, total_relationships} =
          if extractor do
            process_chunks_concurrently(
              chunk_records,
              collection_id,
              repo,
              progress_fn,
              total_chunks,
              concurrency,
              &extract_single_chunk_combined(&1, extractor)
            )
          else
            entity_extractor = resolve_entity_extractor(opts)
            relationship_extractor = resolve_relationship_extractor(opts, graph_config)

            process_chunks_concurrently(
              chunk_records,
              collection_id,
              repo,
              progress_fn,
              total_chunks,
              concurrency,
              &extract_single_chunk_separate(&1, entity_extractor, relationship_extractor)
            )
          end

        entity_count = map_size(entity_id_map)
        result = {:ok, %{entity_count: entity_count, relationship_count: total_relationships}}
        {result, %{entity_count: entity_count, relationship_count: total_relationships}}
      end
    )
  end

  defp process_chunks_concurrently(
         chunks,
         collection_id,
         repo,
         progress_fn,
         total_chunks,
         concurrency,
         extract_fn
       ) do
    # Use Task.async_stream for parallel extraction, ordered results
    # Persistence happens sequentially to maintain entity_id_map consistency
    chunks
    |> Enum.with_index(1)
    |> Task.async_stream(
      fn {chunk, index} ->
        # Extract in parallel (the slow LLM part)
        {entities, mentions, relationships} = extract_fn.(chunk)
        {index, entities, mentions, relationships}
      end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce({%{}, 0}, fn {:ok, {index, entities, mentions, relationships}},
                                {entity_id_map, rel_count} ->
      # Persist sequentially (fast DB operations)
      {:ok, new_entity_ids} =
        GraphStore.persist_entities(collection_id, entities, repo: repo)

      merged_entity_id_map = Map.merge(entity_id_map, new_entity_ids)

      :ok = GraphStore.persist_mentions(mentions, merged_entity_id_map, repo: repo)
      :ok = GraphStore.persist_relationships(relationships, merged_entity_id_map, repo: repo)

      # Report progress
      progress_fn.(index, total_chunks)

      {merged_entity_id_map, rel_count + length(relationships)}
    end)
  end

  defp extract_single_chunk_combined(chunk, extractor) do
    case GraphExtractor.extract(extractor, chunk.text) do
      {:ok, %{entities: entities, relationships: relationships}} ->
        mentions =
          Enum.map(entities, fn entity ->
            %{
              entity_name: entity.name,
              chunk_id: chunk.id,
              span_start: entity[:span_start],
              span_end: entity[:span_end]
            }
          end)

        {entities, mentions, relationships}

      {:error, _reason} ->
        {[], [], []}
    end
  end

  defp extract_single_chunk_separate(chunk, entity_extractor, relationship_extractor) do
    case EntityExtractor.extract(entity_extractor, chunk.text) do
      {:ok, entities} ->
        mentions =
          Enum.map(entities, fn entity ->
            %{
              entity_name: entity.name,
              chunk_id: chunk.id,
              span_start: entity[:span_start],
              span_end: entity[:span_end]
            }
          end)

        relationships = extract_relationships(chunk, entities, relationship_extractor)
        {entities, mentions, relationships}

      {:error, _reason} ->
        {[], [], []}
    end
  end

  defp extract_relationships(_chunk, _entities, nil), do: []

  defp extract_relationships(chunk, entities, relationship_extractor) do
    entity_names = Enum.map(entities, & &1.name)

    case RelationshipExtractor.extract(relationship_extractor, chunk.text, entity_names) do
      {:ok, relationships} -> relationships
      {:error, _reason} -> []
    end
  end

  @doc """
  Resolves the entity extractor from options and config.
  """
  def resolve_entity_extractor(opts) do
    graph_config = config()
    llm = opts[:llm] || Application.get_env(:arcana, :llm)
    extractor = Keyword.get(opts, :entity_extractor) || graph_config[:entity_extractor]
    normalize_entity_extractor(extractor, llm)
  end

  # Private graph building functions

  defp normalize_entity_extractor(nil, _llm), do: {EntityExtractor.NER, []}
  defp normalize_entity_extractor(:ner, _llm), do: {EntityExtractor.NER, []}
  defp normalize_entity_extractor({module, opts}, llm), do: {module, maybe_inject_llm(opts, llm)}
  defp normalize_entity_extractor(fun, _llm) when is_function(fun, 2), do: fun

  defp normalize_entity_extractor(module, llm) when is_atom(module),
    do: {module, maybe_inject_llm([], llm)}

  defp maybe_inject_llm(opts, nil), do: opts
  defp maybe_inject_llm(opts, llm), do: Keyword.put_new(opts, :llm, llm)

  defp resolve_relationship_extractor(opts, graph_config) do
    llm = opts[:llm] || Application.get_env(:arcana, :llm)

    case Keyword.get(opts, :relationship_extractor) do
      nil ->
        case graph_config[:relationship_extractor] do
          nil -> nil
          {module, extractor_opts} -> {module, maybe_inject_llm(extractor_opts, llm)}
          module when is_atom(module) -> {module, maybe_inject_llm([], llm)}
          fun when is_function(fun, 3) -> fun
        end

      {module, extractor_opts} ->
        {module, maybe_inject_llm(extractor_opts, llm)}

      extractor ->
        extractor
    end
  end

  defp resolve_extractor(opts, graph_config) do
    llm = opts[:llm] || Application.get_env(:arcana, :llm)

    case Keyword.get(opts, :extractor) do
      nil ->
        case graph_config[:extractor] do
          nil -> nil
          {module, extractor_opts} -> {module, maybe_inject_llm(extractor_opts, llm)}
          module when is_atom(module) -> {module, maybe_inject_llm([], llm)}
          fun when is_function(fun, 2) -> fun
        end

      {module, extractor_opts} ->
        {module, maybe_inject_llm(extractor_opts, llm)}

      extractor ->
        extractor
    end
  end
end
