defmodule Arcana.Search do
  @moduledoc """
  Search functionality for Arcana.

  Provides vector, keyword, and hybrid search modes with optional
  GraphRAG enhancement using Reciprocal Rank Fusion (RRF).

  ## Mode names

  Canonical mode atoms are `:vector`, `:keyword`, and `:hybrid`. The
  old names `:semantic` and `:fulltext` are still accepted as aliases
  for `:vector` and `:keyword` respectively, with a deprecation warning
  logged on use. The old names will be removed in a future release.
  """

  require Logger

  alias Arcana.{Collection, Embedder, VectorStore}
  alias Arcana.VectorStore.Pgvector

  @valid_modes [:vector, :keyword, :hybrid]

  @deprecated_mode_aliases %{
    semantic: :vector,
    fulltext: :keyword
  }

  @doc """
  Normalizes a search mode atom. Accepts the canonical `:vector`,
  `:keyword`, `:hybrid` or the deprecated aliases `:semantic` and
  `:fulltext` (with a one-line warning). Unknown values pass through
  unchanged so the caller's validation surfaces them with context.
  """
  def normalize_mode(mode) when mode in [:vector, :keyword, :hybrid], do: mode

  def normalize_mode(mode) when is_map_key(@deprecated_mode_aliases, mode) do
    canonical = @deprecated_mode_aliases[mode]

    Logger.warning(
      "[Arcana.Search] mode: #{inspect(mode)} is deprecated, use #{inspect(canonical)}. " <>
        "The old alias will be removed in a future release."
    )

    canonical
  end

  def normalize_mode(other), do: other

  @doc """
  Searches for chunks similar to the query.

  Returns `{:ok, results}` where results is a list of maps containing chunk
  information and similarity scores, or `{:error, reason}` on failure.

  ## Options

    * `:repo` - The Ecto repo to use (required for pgvector backend)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:threshold` - Minimum similarity score (default: 0.0)
    * `:mode` - Search mode: `:vector` (default), `:keyword`, or `:hybrid`.
      `:semantic` and `:fulltext` are deprecated aliases.
    * `:collection` - Filter results to a specific collection by name
    * `:vector_store` - Override the configured vector store backend
    * `:vector_weight` - Weight for vector scores in hybrid mode (default: 0.5)
    * `:keyword_weight` - Weight for keyword scores in hybrid mode (default: 0.5)
    * `:reranker` - Reranker module or function. Defaults to `config :arcana, :reranker`.
      Pass `false` to disable a globally configured reranker for this call.
      When set, retrieves `limit * over_fetch` candidates, reranks, returns top `limit`.

  Defaults for `:limit`, `:threshold`, and `:mode` can be set globally:

      config :arcana, search: [limit: 10, threshold: 0.0, mode: :vector]

  """
  def search(query, opts) when is_binary(query) do
    opts = Arcana.Config.merge_app_opts(opts, :search)
    repo = Arcana.Config.get(opts, :repo)
    reranker = Arcana.Config.reranker(opts)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)
    mode = normalize_mode(Keyword.get(opts, :mode, :vector))
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

      warn_deprecated_weight_opts(opts)

      params = %{
        repo: repo,
        limit: retrieval_limit,
        source_id: source_id,
        threshold: threshold,
        vector_store: vector_store_opt,
        vector_weight: Keyword.get(opts, :vector_weight, 0.5),
        keyword_weight: Keyword.get(opts, :keyword_weight, 0.5),
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

    {matcher, matcher_opts} = resolve_entity_matcher(opts, graph_config)
    matcher_opts = matcher_opts |> Keyword.put(:repo, repo) |> Keyword.merge(opts)

    case matcher.match(query, collection_ids, matcher_opts) do
      {:ok, entity_ids} when entity_ids != [] ->
        :telemetry.span(
          [:arcana, :graph, :search],
          %{query: query, entity_count: length(entity_ids), matcher: matcher},
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
              matcher: matcher
            }

            {{{:ok, final_results}, caller_result}, telemetry_metadata}
          end
        )

      _ ->
        format_search_results({:ok, vector_results}, limit)
    end
  end

  defp resolve_entity_matcher(opts, graph_config) do
    value =
      opts[:entity_matcher] ||
        graph_config[:entity_matcher] ||
        Arcana.Graph.EntityMatcher.Embedding

    Arcana.Config.parse_entity_matcher_config(value)
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

  defp do_search(:vector, query, params) do
    case Embedder.embed(Arcana.Config.embedder(), query, intent: :query) do
      {:ok, query_embedding} ->
        vector_store_opts = build_vector_store_opts(params, [:limit, :threshold, :source_id])
        results = VectorStore.search(params.collection, query_embedding, vector_store_opts)

        {:ok, transform_results(results)}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  defp do_search(:keyword, query, params) do
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
            vector_weight: Map.get(params, :vector_weight, 0.5),
            keyword_weight: Map.get(params, :keyword_weight, 0.5)
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
             vector_score: metadata[:vector_score],
             keyword_score: metadata[:keyword_score]
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
    vector_params = %{params | limit: params.limit * pool}
    keyword_params = %{params | limit: params.limit * pool}

    with {:ok, vector_results} <- do_search(:vector, query, vector_params),
         {:ok, keyword_results} <- do_search(:keyword, query, keyword_params) do
      {:ok, rrf_combine(vector_results, keyword_results, params.limit, rrf_k)}
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

  defp warn_deprecated_weight_opts(opts) do
    if Keyword.has_key?(opts, :semantic_weight) do
      Logger.warning(
        "[Arcana.Search] :semantic_weight is deprecated and ignored, use :vector_weight."
      )
    end

    if Keyword.has_key?(opts, :fulltext_weight) do
      Logger.warning(
        "[Arcana.Search] :fulltext_weight is deprecated and ignored, use :keyword_weight."
      )
    end
  end
end
