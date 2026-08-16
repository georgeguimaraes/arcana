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

          # Community detection
          community_levels: 1,      # Hierarchy depth for Leiden algorithm (1 = flat)
          resolution: 1.0,          # Leiden granularity (lower = fewer, larger communities)
          min_size: 1,              # Minimum community size

          # RRF fusion (combining vector + graph search results)
          rrf_k: 60,               # Ranking constant (higher = less weight to top ranks)
          rrf_pool_multiplier: 2,  # Over-fetch multiplier before RRF combine

          # Query-time graph traversal
          query_depth: 0,          # Hops to expand matched entities (0 = direct mentions only)
          query_depth_decay: 0.5,  # Score decay per hop for chunks reached via traversal

          # Community summaries in ask pipeline
          community_summary_limit: 5,  # Max summaries injected as background context
          community_summary_level: 0,  # Level(s) to pull summaries from: integer, list, range or :all

          # Community summarization prompt limits
          summary_max_entities: 50,       # Top N entities by connection count per summary
          summary_max_relationships: 100, # Top N relationships per summary

          # Entity matcher (pluggable)
          entity_matcher: :embedding,      # :embedding (default), :ner, or custom module
          entity_embedding_threshold: 0.3, # Threshold for the :embedding matcher

          # Structured context in ask pipeline (GraphRAG Local Search)
          context_entity_limit: 10,        # Max entity descriptions in LLM context
          context_relationship_limit: 20   # Max relationships in LLM context
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
    community_levels: 1,
    resolution: 1.0,
    min_size: 1,
    rrf_k: 60,
    rrf_pool_multiplier: 2,
    query_depth: 0,
    query_depth_decay: 0.5,
    community_summary_limit: 5,
    community_summary_level: 0,
    summary_max_entities: 50,
    summary_max_relationships: 100,
    entity_embedding_threshold: 0.3,
    context_entity_limit: 10,
    context_relationship_limit: 20
  }

  @doc """
  Returns the current GraphRAG configuration.

  ## Example

      Arcana.Graph.config()
      # => %{enabled: false, community_levels: 1, resolution: 1.0}

  """
  def config do
    raw_config()
    |> sanitize_for_serialization()
  end

  # Returns raw config including non-serializable values (for internal use)
  defp raw_config do
    app_config = Arcana.Config.get_env(:graph, [])

    @default_config
    |> Map.merge(Map.new(app_config))
  end

  # Filter out non-serializable values (functions, pids, etc.)
  defp sanitize_for_serialization(config) do
    config
    |> Enum.reject(fn {_k, v} -> is_function(v) or is_pid(v) or is_reference(v) end)
    |> Map.new()
  end

  @doc """
  Returns the community hierarchy levels that queries read summaries from.

  Configured with `community_summary_level`, which accepts an integer, a
  list of integers, a range, or `:all`. Summarization consumes the same
  key, so the levels that get summarized and the levels `ask/2` reads
  can't drift apart.

  Returns `:all` or a list of levels.

  ## Examples

      Arcana.Graph.summary_levels()
      # => [0]

  """
  def summary_levels(config \\ config()) do
    normalize_levels(config[:community_summary_level])
  end

  @doc """
  Normalizes a level selection into `:all` or a list of levels.
  """
  def normalize_levels(nil), do: [0]
  def normalize_levels(:all), do: :all
  def normalize_levels(level) when is_integer(level), do: [level]
  def normalize_levels(first..last//step), do: Enum.to_list(first..last//step)

  def normalize_levels(levels) when is_list(levels) do
    if Enum.all?(levels, &is_integer/1) do
      levels
    else
      raise ArgumentError, "community summary levels must be integers, got: #{inspect(levels)}"
    end
  end

  def normalize_levels(other) do
    raise ArgumentError,
          "invalid community summary level: #{inspect(other)} " <>
            "(expected an integer, a list, a range or :all)"
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
  Resolves the query-time graph traversal depth from per-call opts and
  global config.

  Reads `:graph_depth` from `opts` first, then falls back to
  `config :arcana, graph: [query_depth: n]` (default 0). Raises
  `ArgumentError` on anything other than a non-negative integer.
  """
  def query_depth(opts) do
    depth =
      case Keyword.fetch(opts, :graph_depth) do
        # `false` disables traversal, matching the `reranker: false` idiom
        {:ok, false} -> 0
        {:ok, value} -> value
        :error -> config()[:query_depth] || 0
      end

    unless is_integer(depth) and depth >= 0 do
      raise ArgumentError,
            "graph_depth must be a non-negative integer, got: #{inspect(depth)}"
    end

    depth
  end

  @doc """
  Expands entity ids through the relationships table for `depth` hops.

  Walks `arcana_graph_relationships` breadth-first (both directions) from
  the given entity ids, returning a map of hop distance to the entity ids
  first discovered at that hop: `%{0 => direct_ids, 1 => neighbors, ...}`.
  Each entity appears once, at its minimal hop distance.

  `collection_ids` follows the usual scoping semantics: `nil` is unscoped,
  a list restricts discovered neighbors to those collections, and an empty
  list matches nothing (no neighbors are pulled in).

  ## Options

    * `:repo` - Ecto repo (required)

  """
  def expand_entity_ids(entity_ids, depth, collection_ids, opts)

  def expand_entity_ids([], _depth, _collection_ids, _opts), do: %{}

  def expand_entity_ids(entity_ids, 0, _collection_ids, _opts),
    do: %{0 => Enum.uniq(entity_ids)}

  def expand_entity_ids(entity_ids, depth, collection_ids, opts)
      when is_integer(depth) and depth > 0 do
    repo = Keyword.fetch!(opts, :repo)
    frontier = Enum.uniq(entity_ids)

    do_expand(frontier, MapSet.new(frontier), %{0 => frontier}, 1, depth, collection_ids, repo)
  end

  defp do_expand(frontier, visited, acc, hop, depth, collection_ids, repo)

  defp do_expand(_frontier, _visited, acc, hop, depth, _collection_ids, _repo)
       when hop > depth,
       do: acc

  defp do_expand(frontier, visited, acc, hop, depth, collection_ids, repo) do
    neighbors =
      frontier
      |> neighbor_entity_ids(collection_ids, repo)
      |> Enum.reject(&MapSet.member?(visited, &1))

    case neighbors do
      [] ->
        acc

      ids ->
        visited = MapSet.union(visited, MapSet.new(ids))
        do_expand(ids, visited, Map.put(acc, hop, ids), hop + 1, depth, collection_ids, repo)
    end
  end

  # One query per hop: joining both endpoints carries each neighbor's
  # collection along, so scoping needs no second round trip.
  defp neighbor_entity_ids(frontier, collection_ids, repo) do
    import Ecto.Query

    repo.all(
      from(r in Arcana.Graph.Relationship,
        join: s in Arcana.Graph.Entity,
        on: s.id == r.source_id,
        join: t in Arcana.Graph.Entity,
        on: t.id == r.target_id,
        where: r.source_id in ^frontier or r.target_id in ^frontier,
        select: {r.source_id, s.collection_id, r.target_id, t.collection_id}
      )
    )
    |> Enum.flat_map(fn {source, source_collection, target, target_collection} ->
      [{source, source_collection}, {target, target_collection}]
    end)
    |> Enum.filter(fn {_id, collection_id} -> in_scope?(collection_id, collection_ids) end)
    |> Enum.map(fn {id, _collection_id} -> id end)
    |> Enum.uniq()
  end

  # nil means unscoped; a list scopes traversal, and an empty list
  # expands nothing (same semantics as collection filters elsewhere).
  defp in_scope?(_collection_id, nil), do: true
  defp in_scope?(collection_id, collection_ids), do: collection_id in collection_ids

  # nil means unscoped; a list scopes the expansion, and an empty list must
  # match nothing (`in []` compiles to false) — never fall back to global.

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

    # Carry a per-call :graph_store through to persistence, so a build and
    # the sweep that follows it (Arcana.delete/2, replace ingest) always
    # hit the same backend instead of one going to the configured default.
    store_opts = opts |> Keyword.take([:graph_store]) |> Keyword.put(:repo, repo)

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
              store_opts,
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
              store_opts,
              progress_fn,
              total_chunks,
              concurrency,
              &extract_single_chunk_separate(&1, entity_extractor, relationship_extractor)
            )
          end

        # Distinct ids, not keys: a store may key one row under several
        # names (the Ecto store keys every raw spelling as well as the
        # normalized one, see its persist_entities/3), and this number is
        # what the documents and maintenance UIs show as "entities".
        entity_count = entity_id_map |> Map.values() |> Enum.uniq() |> length()
        result = {:ok, %{entity_count: entity_count, relationship_count: total_relationships}}
        {result, %{entity_count: entity_count, relationship_count: total_relationships}}
      end
    )
  end

  defp process_chunks_concurrently(
         chunks,
         collection_id,
         store_opts,
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
        # Extract in parallel (the slow LLM part).
        #
        # Catch here, inside the task, and carry the failure back as a
        # value. Task.async_stream links: an extractor that raises, throws
        # or exits would otherwise kill this task, and the link exit signal
        # would take the caller down with it — signals aren't catchable, so
        # neither the rescue nor a catch in Arcana.Ingest would run and the
        # document would be stranded at :processing. The reducer re-raises
        # the original kind/reason/stacktrace in the caller instead, where
        # it unwinds through the code that marks the document :failed.
        #
        # A task killed from the outside (:kill) is still unrecoverable
        # here; nothing short of an unlinked task covers that.
        try do
          {entities, mentions, relationships} = extract_fn.(chunk)
          {:extracted, index, entities, mentions, relationships}
        catch
          kind, reason -> {:extract_failed, kind, reason, __STACKTRACE__}
        end
      end,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.reduce({%{}, 0}, fn
      {:ok, {:extract_failed, kind, reason, stacktrace}}, _acc ->
        # Before persisting anything for this chunk, so a failed extraction
        # leaves no half-written chunk behind.
        :erlang.raise(kind, reason, stacktrace)

      {:ok, {:extracted, index, entities, mentions, relationships}}, {entity_id_map, rel_count} ->
        # Embed entity descriptions for GraphRAG-style entity search.
        # Stays outside the write lock: it can hit a model, and the lock is
        # for DB writes only.
        entities = maybe_embed_entities(entities)

        merged_entity_id_map =
          persist_chunk_graph(
            collection_id,
            entities,
            mentions,
            relationships,
            entity_id_map,
            store_opts
          )

        # Report progress
        progress_fn.(index, total_chunks)

        {merged_entity_id_map, rel_count + length(relationships)}
    end)
  end

  # Entities, their mentions and their relationships land together under
  # the collection's write lock, so a concurrent sweep_orphans can't run
  # between the entity insert and the mention insert and delete an entity
  # that is about to be referenced.
  #
  # Atomicity here is store-dependent (see GraphStore.with_write_lock/3).
  # The :ecto backend holds the lock inside a transaction, so a failure
  # anywhere in the trio rolls the whole chunk back. The :memory backend
  # and custom stores that skip the optional callback just run the trio,
  # so a failure mid-trio leaves that chunk's graph data half-persisted;
  # the raise then aborts the build. Nothing downstream cleans that up,
  # and no caller of build_and_persist/4 treats a failed build as having
  # left the graph untouched.
  defp persist_chunk_graph(
         collection_id,
         entities,
         mentions,
         relationships,
         entity_id_map,
         store_opts
       ) do
    GraphStore.with_write_lock(collection_id, store_opts, fn ->
      {:ok, new_entity_ids} = GraphStore.persist_entities(collection_id, entities, store_opts)

      merged_entity_id_map = Map.merge(entity_id_map, new_entity_ids)

      :ok = GraphStore.persist_mentions(mentions, merged_entity_id_map, store_opts)
      :ok = GraphStore.persist_relationships(relationships, merged_entity_id_map, store_opts)

      merged_entity_id_map
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
    graph_config = raw_config()
    llm = Arcana.Config.get(opts, :llm)
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
    llm = Arcana.Config.get(opts, :llm)

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

  defp maybe_embed_entities(entities) do
    embedder = Arcana.Config.embedder()

    entities
    |> Enum.map(fn entity ->
      if entity[:embedding] do
        entity
      else
        text =
          case entity[:description] do
            nil -> entity.name
            "" -> entity.name
            desc -> "#{entity.name}: #{desc}"
          end

        case Arcana.Embedder.embed(embedder, text, intent: :document) do
          {:ok, embedding} -> Map.put(entity, :embedding, embedding)
          _ -> entity
        end
      end
    end)
  end

  defp resolve_extractor(opts, graph_config) do
    llm = Arcana.Config.get(opts, :llm)

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
