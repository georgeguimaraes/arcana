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

  """
  def search(query, opts) when is_binary(query) do
    repo = opts[:repo] || Application.get_env(:arcana, :repo)
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

      params = %{
        repo: repo,
        limit: limit,
        source_id: source_id,
        threshold: threshold,
        vector_store: vector_store_opt,
        semantic_weight: Keyword.get(opts, :semantic_weight, 0.5),
        fulltext_weight: Keyword.get(opts, :fulltext_weight, 0.5)
      }

      collection_results = search_collections(collections, mode, search_query, params)

      if Arcana.Config.graph_enabled?(opts) and repo do
        enhance_with_graph_search(collection_results, search_query, collections, repo, opts)
      else
        format_search_results(collection_results, limit)
      end
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
    entity_extractor = Arcana.Graph.resolve_entity_extractor(opts)

    case EntityExtractor.extract(entity_extractor, query) do
      {:ok, entities} when entities != [] ->
        :telemetry.span(
          [:arcana, :graph, :search],
          %{query: query, entity_count: length(entities)},
          fn ->
            graph_results = graph_search_db(entities, collections, repo)
            combined = rrf_combine(vector_results, graph_results, limit * 2)
            final_results = Enum.take(combined, limit)

            caller_result = %{
              results: final_results,
              result_count: length(final_results),
              graph_enhanced: true,
              entities_found: length(entities)
            }

            telemetry_metadata = %{
              graph_result_count: length(graph_results),
              combined_count: length(final_results)
            }

            {{{:ok, final_results}, caller_result}, telemetry_metadata}
          end
        )

      _ ->
        format_search_results({:ok, vector_results}, limit)
    end
  end

  defp graph_search_db(entities, collections, repo) do
    entity_names = Enum.map(entities, & &1.name)
    collection_ids = resolve_collection_ids(collections, repo)

    GraphStore.search(entity_names, collection_ids, repo: repo)
    |> Enum.map(fn result -> Map.put(result, :id, result.chunk_id) end)
  end

  defp resolve_collection_ids([nil], _repo), do: nil

  defp resolve_collection_ids(collections, repo) do
    import Ecto.Query

    collections
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn name ->
      case repo.one(from(c in Collection, where: c.name == ^name, select: c.id)) do
        nil -> []
        id -> [id]
      end
    end)
  end

  defp do_search(:semantic, query, params) do
    case Embedder.embed(Arcana.Config.embedder(), query) do
      {:ok, query_embedding} ->
        vector_store_opts =
          [
            limit: params.limit,
            threshold: params.threshold,
            source_id: params.source_id
          ]
          |> maybe_add_repo(params.repo)
          |> maybe_add_vector_store(params.vector_store)

        results = VectorStore.search(params.collection, query_embedding, vector_store_opts)

        {:ok, transform_results(results)}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  defp do_search(:fulltext, query, params) do
    vector_store_opts =
      [
        limit: params.limit,
        source_id: params.source_id
      ]
      |> maybe_add_repo(params.repo)
      |> maybe_add_vector_store(params.vector_store)

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
    case Embedder.embed(Arcana.Config.embedder(), query) do
      {:ok, query_embedding} ->
        opts = [
          repo: params.repo,
          limit: params.limit,
          source_id: params.source_id,
          threshold: params.threshold,
          semantic_weight: Map.get(params, :semantic_weight, 0.5),
          fulltext_weight: Map.get(params, :fulltext_weight, 0.5)
        ]

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
             id: result.id,
             text: metadata[:text] || "",
             document_id: metadata[:document_id],
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
    semantic_params = %{params | limit: params.limit * 2}
    fulltext_params = %{params | limit: params.limit * 2}

    with {:ok, semantic_results} <- do_search(:semantic, query, semantic_params),
         {:ok, fulltext_results} <- do_search(:fulltext, query, fulltext_params) do
      {:ok, rrf_combine(semantic_results, fulltext_results, params.limit)}
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

  defp maybe_add_repo(opts, nil), do: opts
  defp maybe_add_repo(opts, repo), do: Keyword.put(opts, :repo, repo)

  defp maybe_add_vector_store(opts, nil), do: opts
  defp maybe_add_vector_store(opts, vector_store), do: Keyword.put(opts, :vector_store, vector_store)

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
