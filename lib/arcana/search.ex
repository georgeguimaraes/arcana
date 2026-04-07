defmodule Arcana.Search do
  @moduledoc """
  Search functionality for Arcana.

  Provides semantic, fulltext, and hybrid search modes with optional
  GraphRAG enhancement using Reciprocal Rank Fusion (RRF).
  """

  alias Arcana.{Collection, Embedder, VectorStore}
  alias Arcana.Graph.{EntityExtractor, GraphStore}
  alias Arcana.VectorStore.Pgvector

  @valid_modes [:semantic, :fulltext, :hybrid]

  @doc """
  Searches for chunks similar to the query.

  Returns `{:ok, results}` where results is a list of maps containing chunk
  information and similarity scores, or `{:error, reason}` on failure.

  ## Options

    * `:repo` - The Ecto repo to use (required for pgvector backend)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:threshold` - Minimum similarity score (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:collection` - Filter results to a specific collection by name
    * `:vector_store` - Override the configured vector store backend
    * `:semantic_weight` - Weight for semantic scores in hybrid mode (default: 0.5)
    * `:fulltext_weight` - Weight for fulltext scores in hybrid mode (default: 0.5)
    * `:reranker` - Reranker module or function. Defaults to `config :arcana, :reranker`.
      Pass `false` to disable a globally configured reranker for this call.
      When set, retrieves `limit * over_fetch` candidates, reranks, returns top `limit`.

  Defaults for `:limit`, `:threshold`, and `:mode` can be set globally:

      config :arcana, search: [limit: 10, threshold: 0.0, mode: :semantic]

  """
  def search(query, opts) when is_binary(query) do
    opts = Arcana.Config.merge_app_opts(opts, :search)
    repo = Arcana.Config.get(opts, :repo)
    reranker = Arcana.Config.reranker(opts)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)
    mode = Keyword.get(opts, :mode, :semantic)
    rewriter = Keyword.get(opts, :rewriter)
    vector_store_opt = Keyword.get(opts, :vector_store)

    collections =
      cond do
        Keyword.has_key?(opts, :collections) -> Keyword.get(opts, :collections)
        Keyword.has_key?(opts, :collection) -> [Keyword.get(opts, :collection)]
        true -> [nil]
      end

    unless mode in @valid_modes do
      raise ArgumentError,
            "invalid search mode: #{inspect(mode)}. Must be one of #{inspect(@valid_modes)}"
    end

    start_metadata = %{
      query: query,
      repo: repo,
      mode: mode,
      limit: limit
    }

    :telemetry.span([:arcana, :search], start_metadata, fn ->
      search_query = maybe_rewrite_query(query, rewriter)
      over_fetch = reranker_over_fetch(reranker)
      retrieval_limit = if reranker, do: limit * over_fetch, else: limit

      params = %{
        repo: repo,
        limit: retrieval_limit,
        source_id: source_id,
        threshold: threshold,
        vector_store: vector_store_opt,
        semantic_weight: Keyword.get(opts, :semantic_weight, 0.5),
        fulltext_weight: Keyword.get(opts, :fulltext_weight, 0.5),
        # Original opts so backends can pick up any extra knobs (e.g. :hnsw_ef_search)
        opts: opts
      }

      retrieval_opts = Keyword.put(opts, :limit, retrieval_limit)

      collection_results = search_collections(collections, mode, search_query, params)

      search_result =
        if Arcana.Config.graph_enabled?(opts) and repo do
          enhance_with_graph_search(
            collection_results,
            search_query,
            collections,
            repo,
            retrieval_opts
          )
        else
          format_search_results(collection_results, retrieval_limit)
        end

      maybe_rerank(search_result, reranker, search_query, limit, opts)
    end)
  end

  @doc """
  Rewrites a query using a provided rewriter function.

  Query rewriting can improve retrieval by expanding abbreviations,
  adding synonyms, or reformulating the query for better matching.

  ## Options

    * `:rewriter` - A function that takes a query and returns {:ok, rewritten} or {:error, reason}

  """
  def rewrite_query(query, opts \\ []) when is_binary(query) do
    case Keyword.get(opts, :rewriter) do
      nil ->
        {:error, :no_rewriter_configured}

      rewriter_fn when is_function(rewriter_fn, 1) ->
        rewriter_fn.(query)
    end
  end

  # Private functions

  defp reranker_over_fetch(nil), do: 1
  defp reranker_over_fetch({_module_or_fun, opts}), do: Keyword.get(opts, :over_fetch, 3)

  defp maybe_rerank({{:ok, results}, metadata}, nil, _query, _limit, _opts) do
    {{:ok, results}, metadata}
  end

  defp maybe_rerank({{:error, _} = error, metadata}, _reranker, _query, _limit, _opts) do
    {error, metadata}
  end

  defp maybe_rerank(
         {{:ok, results}, metadata},
         {module_or_fun, reranker_opts},
         query,
         limit,
         opts
       ) do
    rerank_opts =
      reranker_opts
      |> Keyword.merge(Keyword.take(opts, [:threshold, :top_k, :llm]))
      |> Keyword.put_new(:top_k, limit)
      |> Keyword.delete(:over_fetch)

    case do_rerank(module_or_fun, query, results, rerank_opts) do
      {:ok, reranked} ->
        {{:ok, reranked}, Map.put(metadata, :reranked, true)}

      {:error, _} ->
        {{:ok, Enum.take(results, limit)}, metadata}
    end
  end

  defp do_rerank(module, query, chunks, opts) when is_atom(module) do
    module.rerank(query, chunks, opts)
  end

  defp do_rerank(fun, query, chunks, opts) when is_function(fun, 3) do
    fun.(query, chunks, opts)
  end

  defp search_collections(collections, mode, search_query, params) do
    Enum.reduce_while(collections, {:ok, []}, fn collection_name, {:ok, acc} ->
      search_single_collection(mode, search_query, params, collection_name, acc)
    end)
  end

  defp search_single_collection(mode, search_query, params, collection_name, acc) do
    case do_search(mode, search_query, Map.put(params, :collection, collection_name)) do
      {:ok, results} -> {:cont, {:ok, acc ++ results}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp format_search_results({:ok, all_results}, limit) do
    results =
      all_results
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(limit)

    stop_metadata = %{results: results, result_count: length(results)}
    {{:ok, results}, stop_metadata}
  end

  defp format_search_results({:error, reason}, _limit) do
    {{:error, reason}, %{error: reason}}
  end

  defp enhance_with_graph_search({:error, reason}, _query, _collections, _repo, _opts) do
    {{:error, reason}, %{error: reason}}
  end

  defp enhance_with_graph_search({:ok, vector_results}, query, collections, repo, opts) do
    limit = Keyword.get(opts, :limit, 10)
    graph_config = Arcana.Graph.config()
    rrf_k = graph_config[:rrf_k] || 60
    rrf_pool = graph_config[:rrf_pool_multiplier] || 2
    collection_ids = resolve_collection_ids(collections, repo)

    # Try embedding-based entity search first, fall back to NER
    matched_entity_ids = find_entities_by_embedding(query, collection_ids, repo, graph_config)

    {entity_ids, match_method} =
      if matched_entity_ids != [] do
        {matched_entity_ids, :embedding}
      else
        find_entities_by_ner(query, collection_ids, repo, opts)
      end

    if entity_ids != [] do
      :telemetry.span(
        [:arcana, :graph, :search],
        %{query: query, entity_count: length(entity_ids), method: match_method},
        fn ->
          graph_results = graph_search_by_entity_ids(entity_ids, repo)
          combined = rrf_combine(vector_results, graph_results, limit * rrf_pool, rrf_k)
          final_results = Enum.take(combined, limit)

          caller_result = %{
            results: final_results,
            result_count: length(final_results),
            graph_enhanced: true,
            entities_found: length(entity_ids)
          }

          telemetry_metadata = %{
            graph_result_count: length(graph_results),
            combined_count: length(final_results),
            match_method: match_method
          }

          {{{:ok, final_results}, caller_result}, telemetry_metadata}
        end
      )
    else
      format_search_results({:ok, vector_results}, limit)
    end
  end

  defp find_entities_by_embedding(query, collection_ids, repo, graph_config) do
    threshold = graph_config[:entity_embedding_threshold] || 0.3
    embedder = Arcana.Config.embedder()

    case Arcana.Embedder.embed(embedder, query, intent: :query) do
      {:ok, query_embedding} ->
        GraphStore.search_by_embedding(query_embedding, collection_ids,
          repo: repo,
          limit: 20,
          threshold: threshold
        )
        |> Enum.map(& &1.id)

      _ ->
        []
    end
  end

  defp find_entities_by_ner(query, collection_ids, repo, opts) do
    import Ecto.Query
    alias Arcana.Graph.Entity
    entity_extractor = Arcana.Graph.resolve_entity_extractor(opts)

    case EntityExtractor.extract(entity_extractor, query) do
      {:ok, entities} when entities != [] ->
        entity_names = Enum.map(entities, & &1.name)

        query =
          from(e in Entity, where: e.name in ^entity_names, select: e.id)

        query =
          if collection_ids && collection_ids != [],
            do: from(e in query, where: e.collection_id in ^collection_ids),
            else: query

        {repo.all(query), :ner}

      _ ->
        {[], :none}
    end
  end

  defp graph_search_by_entity_ids(entity_ids, repo) do
    import Ecto.Query
    alias Arcana.Chunk
    alias Arcana.Graph.EntityMention

    chunk_ids =
      repo.all(
        from(m in EntityMention,
          where: m.entity_id in ^entity_ids,
          select: m.chunk_id,
          distinct: true
        )
      )

    if chunk_ids == [] do
      []
    else
      # Score by mention count
      scored =
        repo.all(
          from(m in EntityMention,
            where: m.chunk_id in ^chunk_ids and m.entity_id in ^entity_ids,
            group_by: m.chunk_id,
            select: %{chunk_id: m.chunk_id, score: count() * 0.1}
          )
        )

      chunk_map =
        repo.all(from(c in Chunk, where: c.id in ^chunk_ids, select: {c.id, c}))
        |> Map.new()

      Enum.flat_map(scored, fn %{chunk_id: cid, score: score} ->
        case Map.get(chunk_map, cid) do
          nil ->
            []

          chunk ->
            [
              %{
                id: chunk.id,
                text: chunk.text,
                document_id: chunk.document_id,
                chunk_index: chunk.chunk_index,
                score: score
              }
            ]
        end
      end)
      |> Enum.sort_by(& &1.score, :desc)
    end
  end

  defp resolve_collection_ids(collections, repo), do: Collection.resolve_ids(collections, repo)

  defp do_search(:semantic, query, params) do
    case Embedder.embed(Arcana.Config.embedder(), query, intent: :query) do
      {:ok, query_embedding} ->
        vector_store_opts = build_vector_store_opts(params, [:limit, :threshold, :source_id])
        results = VectorStore.search(params.collection, query_embedding, vector_store_opts)

        {:ok, transform_results(results)}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  defp do_search(:fulltext, query, params) do
    vector_store_opts = build_vector_store_opts(params, [:limit, :source_id])
    results = VectorStore.search_text(params.collection, query, vector_store_opts)

    {:ok, transform_results(results)}
  end

  defp do_search(:hybrid, query, params) do
    backend = params.vector_store || VectorStore.backend()

    case backend do
      :pgvector ->
        do_hybrid_pgvector(query, params)

      _ ->
        do_hybrid_rrf(query, params)
    end
  end

  defp do_hybrid_pgvector(query, params) do
    case Embedder.embed(Arcana.Config.embedder(), query, intent: :query) do
      {:ok, query_embedding} ->
        user_opts = Map.get(params, :opts, [])

        opts =
          user_opts
          |> Keyword.merge(
            repo: params.repo,
            limit: params.limit,
            source_id: params.source_id,
            threshold: params.threshold,
            semantic_weight: Map.get(params, :semantic_weight, 0.5),
            fulltext_weight: Map.get(params, :fulltext_weight, 0.5)
          )

        results =
          Pgvector.search_hybrid(
            params.collection,
            query_embedding,
            query,
            opts
          )

        {:ok,
         Enum.map(results, fn result ->
           metadata = result.metadata || %{}

           %{
             id: Ecto.UUID.cast!(result.id),
             text: metadata[:text] || "",
             document_id: Ecto.UUID.cast!(metadata[:document_id]),
             chunk_index: metadata[:chunk_index],
             score: result.score,
             semantic_score: metadata[:semantic_score],
             fulltext_score: metadata[:fulltext_score]
           }
         end)}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  defp do_hybrid_rrf(query, params) do
    graph_config = Arcana.Graph.config()
    pool = graph_config[:rrf_pool_multiplier] || 2
    rrf_k = graph_config[:rrf_k] || 60
    semantic_params = %{params | limit: params.limit * pool}
    fulltext_params = %{params | limit: params.limit * pool}

    with {:ok, semantic_results} <- do_search(:semantic, query, semantic_params),
         {:ok, fulltext_results} <- do_search(:fulltext, query, fulltext_params) do
      {:ok, rrf_combine(semantic_results, fulltext_results, params.limit, rrf_k)}
    end
  end

  defp transform_results(results) do
    Enum.map(results, fn result ->
      metadata = result.metadata || %{}

      %{
        id: result.id,
        text: metadata[:text] || "",
        document_id: metadata[:document_id],
        chunk_index: metadata[:chunk_index],
        score: result.score
      }
    end)
  end

  # Build vector_store opts by merging user-provided opts (so backend-specific
  # tuning flows through) with the search-specific fields from params.
  defp build_vector_store_opts(params, fields) do
    user_opts = Map.get(params, :opts, [])

    base =
      Enum.reduce(fields, [], fn field, acc ->
        case Map.get(params, field) do
          nil -> acc
          value -> Keyword.put(acc, field, value)
        end
      end)

    user_opts
    |> Keyword.merge(base)
    |> maybe_add_repo(params.repo)
    |> maybe_add_vector_store(params.vector_store)
  end

  defp maybe_add_repo(opts, nil), do: opts
  defp maybe_add_repo(opts, repo), do: Keyword.put(opts, :repo, repo)

  defp maybe_add_vector_store(opts, nil), do: opts

  defp maybe_add_vector_store(opts, vector_store),
    do: Keyword.put(opts, :vector_store, vector_store)

  defp maybe_rewrite_query(query, nil), do: query

  defp maybe_rewrite_query(query, rewriter) do
    case rewrite_query(query, rewriter: rewriter) do
      {:ok, rewritten} -> rewritten
      {:error, _} -> query
    end
  end

  @doc false
  def rrf_combine(list1, list2, limit, k \\ 60) do
    scores1 =
      list1 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)

    scores2 =
      list2 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)

    all_items =
      (list1 ++ list2)
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn item -> {item.id, item} end)

    all_items
    |> Enum.map(fn {id, item} ->
      rrf_score = Map.get(scores1, id, 0) + Map.get(scores2, id, 0)
      Map.put(item, :score, rrf_score)
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end
end
