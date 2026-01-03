defmodule Arcana do
  @moduledoc """
  RAG (Retrieval Augmented Generation) library for Elixir.

  Arcana provides document ingestion, embedding, and vector search
  capabilities that you can embed into any Phoenix/Ecto application.

  ## Usage

      # Ingest a document
      {:ok, document} = Arcana.ingest("Your text content", repo: MyApp.Repo)

      # Search for relevant chunks
      {:ok, results} = Arcana.search("your query", repo: MyApp.Repo)

      # Delete a document
      :ok = Arcana.delete(document.id, repo: MyApp.Repo)

  """

  alias Arcana.{Chunk, Chunker, Collection, Document, Embedder, LLM, Parser, VectorStore}
  alias Arcana.VectorStore.Pgvector

  alias Arcana.Graph.{
    Entity,
    EntityExtractor,
    EntityMention,
    GraphExtractor,
    Relationship,
    RelationshipExtractor
  }

  @doc """
  Returns the configured embedder as a `{module, opts}` tuple.

  The embedder is configured via application config:

      # Default: Local Bumblebee with bge-small-en-v1.5
      config :arcana, embedder: :local

      # Local with different model
      config :arcana, embedder: {:local, model: "BAAI/bge-large-en-v1.5"}

      # OpenAI (requires req_llm and OPENAI_API_KEY)
      config :arcana, embedder: :openai
      config :arcana, embedder: {:openai, model: "text-embedding-3-large"}

      # Custom function
      config :arcana, embedder: fn text -> {:ok, embedding} end

      # Custom module implementing Arcana.Embedder behaviour
      config :arcana, embedder: MyApp.CohereEmbedder
      config :arcana, embedder: {MyApp.CohereEmbedder, api_key: "..."}

  ## Custom Embedding Modules

  Implement the `Arcana.Embedder` behaviour:

      defmodule MyApp.CohereEmbedder do
        @behaviour Arcana.Embedder

        @impl true
        def embed(text, opts) do
          api_key = opts[:api_key] || System.get_env("COHERE_API_KEY")
          # Call Cohere API...
          {:ok, embedding}
        end

        @impl true
        def dimensions(_opts), do: 1024
      end

  """
  def embedder do
    Application.get_env(:arcana, :embedder, :local)
    |> parse_embedder_config()
  end

  @doc """
  Returns the configured chunker as a `{module, opts}` tuple.

  The chunker is configured via application config:

      # Default: text_chunker-based chunking
      config :arcana, chunker: :default

      # Default chunker with custom options
      config :arcana, chunker: {:default, chunk_size: 512, chunk_overlap: 100}

      # Custom function (receives text, opts; returns list of chunk maps)
      config :arcana, chunker: fn text, _opts ->
        [%{text: text, chunk_index: 0, token_count: 10}]
      end

      # Custom module implementing Arcana.Chunker behaviour
      config :arcana, chunker: MyApp.SemanticChunker
      config :arcana, chunker: {MyApp.SemanticChunker, model: "..."}

  ## Custom Chunking Modules

  Implement the `Arcana.Chunker` behaviour:

      defmodule MyApp.SemanticChunker do
        @behaviour Arcana.Chunker

        @impl true
        def chunk(text, opts) do
          # Custom chunking logic...
          [%{text: text, chunk_index: 0, token_count: estimate_tokens(text)}]
        end
      end

  """
  def chunker do
    Application.get_env(:arcana, :chunker, :text)
    |> parse_chunker_config()
  end

  @doc """
  Returns the current Arcana configuration.

  Useful for logging, debugging, and storing with evaluation runs
  to track which settings produced which results.

  ## Example

      Arcana.config()
      # => %{
      #   embedding: %{module: Arcana.Embedder.Local, model: "BAAI/bge-small-en-v1.5", dimensions: 384},
      #   vector_store: :pgvector
      # }

  """
  def config do
    {emb_module, emb_opts} = embedder()
    model = Keyword.get(emb_opts, :model, "BAAI/bge-small-en-v1.5")

    %{
      embedding: %{
        module: emb_module,
        model: model,
        dimensions: Arcana.Embedder.dimensions(embedder())
      },
      vector_store: Application.get_env(:arcana, :vector_store, :pgvector),
      reranker: Application.get_env(:arcana, :reranker, Arcana.Reranker.LLM),
      graph: Arcana.Graph.config()
    }
  end

  @doc """
  Returns whether GraphRAG is enabled globally or for specific options.

  Checks the `:graph` option in the provided opts first, then falls back
  to the global configuration.

  ## Examples

      # Check global config
      Arcana.graph_enabled?([])

      # Override with per-call option
      Arcana.graph_enabled?(graph: true)

  """
  @spec graph_enabled?(keyword()) :: boolean()
  def graph_enabled?(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Arcana.Graph.enabled?()
      value -> value
    end
  end

  defp parse_embedder_config(:local), do: {Arcana.Embedder.Local, []}
  defp parse_embedder_config({:local, opts}), do: {Arcana.Embedder.Local, opts}
  defp parse_embedder_config(:openai), do: {Arcana.Embedder.OpenAI, []}
  defp parse_embedder_config({:openai, opts}), do: {Arcana.Embedder.OpenAI, opts}

  defp parse_embedder_config(fun) when is_function(fun, 1),
    do: {Arcana.Embedder.Custom, [fun: fun]}

  defp parse_embedder_config({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp parse_embedder_config(module) when is_atom(module), do: {module, []}

  defp parse_embedder_config(other) do
    raise ArgumentError, "invalid embedding config: #{inspect(other)}"
  end

  defp parse_chunker_config(:default), do: {Arcana.Chunker.Default, []}
  defp parse_chunker_config({:default, opts}), do: {Arcana.Chunker.Default, opts}

  defp parse_chunker_config(fun) when is_function(fun, 2),
    do: {Arcana.Chunker.Custom, [fun: fun]}

  defp parse_chunker_config({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp parse_chunker_config(module) when is_atom(module), do: {module, []}

  defp parse_chunker_config(other) do
    raise ArgumentError, "invalid chunker config: #{inspect(other)}"
  end

  defp resolve_chunker(opts) do
    Keyword.get(opts, :chunker, :default) |> parse_chunker_config()
  end

  @doc """
  Ingests text content, creating a document with embedded chunks.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name (string) or map with name and description (default: "default")

  ## Examples

      {:ok, doc} = Arcana.ingest("Hello world", repo: MyApp.Repo)
      {:ok, doc} = Arcana.ingest("Hello", repo: MyApp.Repo, source_id: "doc-123")
      {:ok, doc} = Arcana.ingest("Hello", repo: MyApp.Repo, collection: "products")

      # With collection description (helps Agent.select/2 make better routing decisions)
      {:ok, doc} = Arcana.ingest("API docs",
        repo: MyApp.Repo,
        collection: %{name: "api", description: "REST API reference documentation"}
      )

  """
  def ingest(text, opts) when is_binary(text) do
    repo =
      opts[:repo] || Application.get_env(:arcana, :repo) ||
        raise ArgumentError, "repo is required"

    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})

    {collection_name, collection_description} =
      parse_collection_opt(Keyword.get(opts, :collection, "default"))

    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunker_config = resolve_chunker(opts)

    start_metadata = %{
      text: text,
      repo: repo,
      collection: collection_name
    }

    :telemetry.span([:arcana, :ingest], start_metadata, fn ->
      # Get or create collection
      {:ok, collection} = Collection.get_or_create(collection_name, repo, collection_description)

      # Create document
      {:ok, document} =
        %Document{}
        |> Document.changeset(%{
          content: text,
          source_id: source_id,
          metadata: metadata,
          status: :processing,
          collection_id: collection.id
        })
        |> repo.insert()

      # Chunk the text
      chunks = Chunker.chunk(chunker_config, text, chunk_opts)

      # Embed and store chunks
      result = embed_and_store_chunks(chunks, document, repo)

      case result do
        {:ok, chunk_records} ->
          finalize_ingest(document, chunk_records, collection, repo, opts)

        {:error, reason} ->
          {{:error, reason}, %{error: reason}}
      end
    end)
  end

  defp finalize_ingest(document, chunk_records, collection, repo, opts) do
    maybe_build_graph(chunk_records, collection, repo, opts)

    {:ok, document} =
      document
      |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
      |> repo.update()

    {{:ok, document}, %{document: document, chunk_count: length(chunk_records)}}
  end

  defp maybe_build_graph(chunk_records, collection, repo, opts) do
    if graph_enabled?(opts) do
      build_and_persist_graph(chunk_records, collection, repo, opts)
    end
  end

  defp embed_and_store_chunks(chunks, document, repo) do
    emb = embedder()

    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      embed_single_chunk(emb, chunk, document, repo, acc)
    end)
  end

  defp embed_single_chunk(emb, chunk, document, repo, acc) do
    case Embedder.embed(emb, chunk.text) do
      {:ok, embedding} ->
        chunk_record =
          %Chunk{}
          |> Chunk.changeset(%{
            text: chunk.text,
            embedding: embedding,
            chunk_index: chunk.chunk_index,
            token_count: chunk.token_count,
            document_id: document.id
          })
          |> repo.insert!()

        {:cont, {:ok, [chunk_record | acc]}}

      {:error, reason} ->
        document
        |> Document.changeset(%{status: :failed})
        |> repo.update()

        {:halt, {:error, {:embedding_failed, reason}}}
    end
  end

  @doc """
  Ingests a file, parsing its content and creating a document with embedded chunks.

  Supports multiple file formats including plain text, markdown, and PDF.
  Use `Arcana.Parser.supported_formats/0` to see all supported extensions.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name to organize the document (default: "default")

  ## Examples

      {:ok, doc} = Arcana.ingest_file("/path/to/file.pdf", repo: MyApp.Repo)
      {:ok, doc} = Arcana.ingest_file("/path/to/doc.txt", repo: MyApp.Repo, source_id: "docs")
      {:ok, doc} = Arcana.ingest_file("/path/to/doc.txt", repo: MyApp.Repo, collection: "products")

  """
  def ingest_file(path, opts) when is_binary(path) do
    case Parser.parse(path) do
      {:ok, text} ->
        content_type = content_type_for_path(path)

        opts =
          opts
          |> Keyword.put(:file_path, path)
          |> Keyword.put(:content_type, content_type)

        ingest_with_attrs(text, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ingest_with_attrs(text, opts) do
    repo =
      opts[:repo] || Application.get_env(:arcana, :repo) ||
        raise ArgumentError, "repo is required"

    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    file_path = Keyword.get(opts, :file_path)
    content_type = Keyword.get(opts, :content_type, "text/plain")
    collection_name = Keyword.get(opts, :collection, "default")
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunker_config = resolve_chunker(opts)

    # Get or create collection
    {:ok, collection} = Collection.get_or_create(collection_name, repo)

    # Create document
    {:ok, document} =
      %Document{}
      |> Document.changeset(%{
        content: text,
        source_id: source_id,
        metadata: metadata,
        file_path: file_path,
        content_type: content_type,
        status: :processing,
        collection_id: collection.id
      })
      |> repo.insert()

    # Chunk the text
    chunks = Chunker.chunk(chunker_config, text, chunk_opts)

    # Embed and store chunks
    emb = embedder()

    result =
      chunks
      |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
        case Embedder.embed(emb, chunk.text) do
          {:ok, embedding} ->
            chunk_record =
              %Chunk{}
              |> Chunk.changeset(%{
                text: chunk.text,
                embedding: embedding,
                chunk_index: chunk.chunk_index,
                token_count: chunk.token_count,
                document_id: document.id
              })
              |> repo.insert!()

            {:cont, {:ok, [chunk_record | acc]}}

          {:error, reason} ->
            # Mark document as failed
            document
            |> Document.changeset(%{status: :failed})
            |> repo.update()

            {:halt, {:error, {:embedding_failed, reason}}}
        end
      end)

    case result do
      {:ok, chunk_records} ->
        # Update document status
        {:ok, document} =
          document
          |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
          |> repo.update()

        {:ok, document}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_type_for_path(path) do
    case Path.extname(path) |> String.downcase() do
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".markdown" -> "text/markdown"
      ".pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
  end

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
    * `:vector_store` - Override the configured vector store backend. See `Arcana.VectorStore`
    * `:semantic_weight` - Weight for semantic scores in hybrid mode (default: 0.5)
    * `:fulltext_weight` - Weight for fulltext scores in hybrid mode (default: 0.5)

  ## Vector Store Backend

  For `:semantic` mode, search uses the globally configured vector store
  (`config :arcana, vector_store: :pgvector | :memory`). This allows using
  the in-memory backend for testing or smaller RAG applications.

  For `:fulltext` and `:hybrid` modes, pgvector is always used since these
  require PostgreSQL full-text search capabilities.

  You can override the vector store per-call:

      # Use a specific memory server
      {:ok, results} = Arcana.search("query", vector_store: {:memory, pid: memory_pid})

      # Use a specific repo with pgvector
      {:ok, results} = Arcana.search("query", vector_store: {:pgvector, repo: OtherRepo})

  ## Examples

      {:ok, results} = Arcana.search("functional programming", repo: MyApp.Repo)
      {:ok, results} = Arcana.search("query", repo: MyApp.Repo, limit: 5, source_id: "doc-123")
      {:ok, results} = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)
      {:ok, results} = Arcana.search("query", repo: MyApp.Repo, collection: "products")

  """
  def search(query, opts) when is_binary(query) do
    repo = opts[:repo] || Application.get_env(:arcana, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)
    mode = Keyword.get(opts, :mode, :semantic)
    rewriter = Keyword.get(opts, :rewriter)
    vector_store_opt = Keyword.get(opts, :vector_store)

    # Determine collection(s) to search
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

    # All modes now work with both memory and pgvector backends

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

      # If graph is enabled, enhance with graph-based search
      if graph_enabled?(opts) and repo do
        enhance_with_graph_search(collection_results, search_query, collections, repo, opts)
      else
        format_search_results(collection_results, limit)
      end
    end)
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
    entity_extractor = resolve_entity_extractor(opts, graph_config)

    # Extract entities from query
    case EntityExtractor.extract(entity_extractor, query) do
      {:ok, entities} when entities != [] ->
        :telemetry.span(
          [:arcana, :graph, :search],
          %{query: query, entity_count: length(entities)},
          fn ->
            # Get graph-based results for each collection
            graph_results = graph_search_db(entities, collections, repo)

            # Combine using RRF
            combined = rrf_combine(vector_results, graph_results, limit * 2)
            final_results = Enum.take(combined, limit)

            # Return value for caller and telemetry stop metadata
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
        # No entities found, return vector results as-is
        format_search_results({:ok, vector_results}, limit)
    end
  end

  defp graph_search_db(entities, collections, repo) do
    import Ecto.Query

    entity_names = Enum.map(entities, & &1.name)
    collection_ids = resolve_collection_ids(collections, repo)
    entity_ids = find_entity_ids(entity_names, collection_ids, repo)

    fetch_and_score_chunks(entity_ids, repo)
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

  defp find_entity_ids(entity_names, collection_ids, repo) do
    import Ecto.Query

    query = from(e in Entity, where: e.name in ^entity_names, select: e.id)

    query =
      if collection_ids,
        do: from(e in query, where: e.collection_id in ^collection_ids),
        else: query

    repo.all(query)
  end

  defp fetch_and_score_chunks([], _repo), do: []

  defp fetch_and_score_chunks(entity_ids, repo) do
    import Ecto.Query

    chunk_ids =
      repo.all(
        from(m in EntityMention,
          where: m.entity_id in ^entity_ids,
          select: m.chunk_id,
          distinct: true
        )
      )

    score_chunks(chunk_ids, entity_ids, repo)
  end

  defp score_chunks([], _entity_ids, _repo), do: []

  defp score_chunks(chunk_ids, entity_ids, repo) do
    import Ecto.Query

    chunks = repo.all(from(c in Chunk, where: c.id in ^chunk_ids, preload: [:document]))

    chunks
    |> Enum.map(&score_chunk(&1, entity_ids, repo))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp score_chunk(chunk, entity_ids, repo) do
    import Ecto.Query

    mention_count =
      repo.one(
        from(m in EntityMention,
          where: m.chunk_id == ^chunk.id and m.entity_id in ^entity_ids,
          select: count()
        )
      )

    %{
      id: chunk.id,
      text: chunk.text,
      document_id: chunk.document_id,
      chunk_index: chunk.chunk_index,
      score: mention_count * 0.1
    }
  end

  defp do_search(:semantic, query, params) do
    case Embedder.embed(embedder(), query) do
      {:ok, query_embedding} ->
        # Build VectorStore options
        vector_store_opts =
          [
            limit: params.limit,
            threshold: params.threshold,
            source_id: params.source_id
          ]
          |> maybe_add_repo(params.repo)
          |> maybe_add_vector_store(params.vector_store)

        # Use VectorStore for semantic search (supports memory and pgvector)
        results = VectorStore.search(params.collection, query_embedding, vector_store_opts)

        # Transform VectorStore result format to Arcana.search format
        {:ok,
         Enum.map(results, fn result ->
           metadata = result.metadata || %{}

           %{
             id: result.id,
             text: metadata[:text] || "",
             document_id: metadata[:document_id],
             chunk_index: metadata[:chunk_index],
             score: result.score
           }
         end)}

      {:error, reason} ->
        {:error, {:embedding_failed, reason}}
    end
  end

  defp do_search(:fulltext, query, params) do
    # Build VectorStore options
    vector_store_opts =
      [
        limit: params.limit,
        source_id: params.source_id
      ]
      |> maybe_add_repo(params.repo)
      |> maybe_add_vector_store(params.vector_store)

    # Use VectorStore for fulltext search (supports memory and pgvector)
    results = VectorStore.search_text(params.collection, query, vector_store_opts)

    # Transform VectorStore result format to Arcana.search format
    {:ok,
     Enum.map(results, fn result ->
       metadata = result.metadata || %{}

       %{
         id: result.id,
         text: metadata[:text] || "",
         document_id: metadata[:document_id],
         chunk_index: metadata[:chunk_index],
         score: result.score
       }
     end)}
  end

  defp do_search(:hybrid, query, params) do
    # Determine which backend to use
    backend = params.vector_store || VectorStore.backend()

    case backend do
      :pgvector ->
        # Use single-query hybrid search for better result coverage
        do_hybrid_pgvector(query, params)

      _ ->
        # Fall back to two-query approach with RRF for other backends
        do_hybrid_rrf(query, params)
    end
  end

  defp do_hybrid_pgvector(query, params) do
    case Embedder.embed(embedder(), query) do
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

        # Transform to Arcana.search format
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
    # Get results from both methods
    semantic_params = %{params | limit: params.limit * 2}
    fulltext_params = %{params | limit: params.limit * 2}

    with {:ok, semantic_results} <- do_search(:semantic, query, semantic_params),
         {:ok, fulltext_results} <- do_search(:fulltext, query, fulltext_params) do
      # Combine using Reciprocal Rank Fusion (RRF)
      {:ok, rrf_combine(semantic_results, fulltext_results, params.limit)}
    end
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

  defp rrf_combine(list1, list2, limit, k \\ 60) do
    # RRF formula: score = sum(1 / (k + rank))
    scores1 =
      list1 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)

    scores2 =
      list2 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)

    # Build a map of all items by id
    all_items =
      (list1 ++ list2)
      |> Enum.uniq_by(& &1.id)
      |> Map.new(fn item -> {item.id, item} end)

    # Combine scores
    all_items
    |> Enum.map(fn {id, item} ->
      rrf_score = Map.get(scores1, id, 0) + Map.get(scores2, id, 0)
      Map.put(item, :score, rrf_score)
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Rewrites a query using a provided rewriter function.

  Query rewriting can improve retrieval by expanding abbreviations,
  adding synonyms, or reformulating the query for better matching.

  ## Options

    * `:rewriter` - A function that takes a query and returns {:ok, rewritten} or {:error, reason}

  ## Examples

      rewriter = fn query -> {:ok, "expanded: \#{query}"} end
      {:ok, rewritten} = Arcana.rewrite_query("ML", rewriter: rewriter)

  """
  def rewrite_query(query, opts \\ []) when is_binary(query) do
    case Keyword.get(opts, :rewriter) do
      nil ->
        {:error, :no_rewriter_configured}

      rewriter_fn when is_function(rewriter_fn, 1) ->
        rewriter_fn.(query)
    end
  end

  @doc """
  Asks a question using retrieved context from the knowledge base.

  Performs a search to find relevant chunks, then passes them along with
  the question to an LLM for answer generation.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:llm` - Any type implementing the `Arcana.LLM` protocol (required).
      This includes anonymous functions, LangChain chat models, or custom implementations.
    * `:limit` - Maximum number of context chunks to retrieve (default: 5)
    * `:source_id` - Filter context to a specific source
    * `:threshold` - Minimum similarity score for context (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:prompt` - Custom prompt function `fn question, context -> system_prompt_string end`

  ## Examples

      # Using an anonymous function
      llm = fn prompt, context -> {:ok, "Generated answer"} end
      {:ok, answer} = Arcana.ask("What is the capital?", repo: MyApp.Repo, llm: llm)

      # Using a LangChain model (when langchain is installed)
      llm = LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"})
      {:ok, answer} = Arcana.ask("What is the capital?", repo: MyApp.Repo, llm: llm)

      # Using a custom prompt
      custom_prompt = fn question, context ->
        "Answer '\#{question}' based on: \#{Enum.map_join(context, ", ", & &1.text)}"
      end
      {:ok, answer} = Arcana.ask("What is the capital?",
        repo: MyApp.Repo,
        llm: llm,
        prompt: custom_prompt
      )

  """
  def ask(question, opts) when is_binary(question) do
    repo = opts[:repo] || Application.get_env(:arcana, :repo)
    llm = opts[:llm] || Application.get_env(:arcana, :llm)

    if is_nil(llm), do: {:error, :no_llm_configured}, else: do_ask(question, opts, repo, llm)
  end

  defp do_ask(question, opts, repo, llm) do
    start_metadata = %{question: question, repo: repo}

    :telemetry.span([:arcana, :ask], start_metadata, fn ->
      search_opts = build_search_opts(opts)

      case search(question, search_opts) do
        {:ok, context} -> ask_with_context(question, context, opts, llm)
        {:error, reason} -> {{:error, {:search_failed, reason}}, %{error: reason}}
      end
    end)
  end

  defp build_search_opts(opts) do
    opts
    |> Keyword.take([:repo, :limit, :source_id, :threshold, :mode, :collection, :collections])
    |> Keyword.put_new(:limit, 5)
  end

  defp ask_with_context(question, context, opts, llm) do
    prompt_fn = Keyword.get(opts, :prompt, &default_ask_prompt/2)
    llm_opts = [system_prompt: prompt_fn.(question, context)]

    result = do_ask_llm(llm, question, context, llm_opts)
    stop_metadata = ask_stop_metadata(result, context)

    {result, stop_metadata}
  end

  @doc """
  Deletes a document and all its chunks.

  ## Options

    * `:repo` - The Ecto repo to use (required)

  ## Examples

      :ok = Arcana.delete(document_id, repo: MyApp.Repo)
      {:error, :not_found} = Arcana.delete(non_existent_id, repo: MyApp.Repo)

  """
  def delete(document_id, opts) do
    repo =
      opts[:repo] || Application.get_env(:arcana, :repo) ||
        raise ArgumentError, "repo is required"

    case repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        repo.delete!(document)
        :ok
    end
  end

  defp default_ask_prompt(_question, context) do
    context_text =
      Enum.map_join(context, "\n\n---\n\n", fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)

    if context_text != "" do
      """
      Answer the user's question based on the following context.
      If the answer is not in the context, say you don't know.

      Context:
      #{context_text}
      """
    else
      "You are a helpful assistant."
    end
  end

  defp ask_stop_metadata({:ok, answer, _context}, context) do
    %{answer: answer, context_count: length(context)}
  end

  defp ask_stop_metadata({:error, _}, context) do
    %{context_count: length(context)}
  end

  defp do_ask_llm(llm, question, context, llm_opts) do
    case LLM.complete(llm, question, context, llm_opts) do
      {:ok, answer} -> {:ok, answer, context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_collection_opt(name) when is_binary(name), do: {name, nil}
  defp parse_collection_opt(%{name: name, description: desc}), do: {name, desc}
  defp parse_collection_opt(%{name: name}), do: {name, nil}

  # GraphRAG integration

  defp build_and_persist_graph(chunk_records, collection, repo, opts) do
    collection_name = if is_binary(collection), do: collection, else: collection.name

    :telemetry.span(
      [:arcana, :graph, :build],
      %{chunk_count: length(chunk_records), collection: collection_name},
      fn ->
        {all_entities, all_mentions, all_relationships} =
          extract_all_graph_data(chunk_records, opts)

        entity_id_map = persist_entities(all_entities, collection, repo)
        persist_entity_mentions(all_mentions, entity_id_map, repo)
        persist_relationships(all_relationships, entity_id_map, repo)

        {:ok,
         %{entity_count: map_size(entity_id_map), relationship_count: length(all_relationships)}}
      end
    )
  end

  defp extract_all_graph_data(chunk_records, opts) do
    graph_config = Arcana.Graph.config()
    extractor = resolve_extractor(opts, graph_config)

    if extractor do
      extract_with_combined_extractor(chunk_records, extractor)
    else
      extract_with_separate_extractors(chunk_records, opts, graph_config)
    end
  end

  defp extract_with_combined_extractor(chunk_records, extractor) do
    Enum.reduce(chunk_records, {[], [], []}, fn chunk, {ent_acc, ment_acc, rel_acc} ->
      extract_graph_data_combined(chunk, extractor, ent_acc, ment_acc, rel_acc)
    end)
  end

  defp extract_with_separate_extractors(chunk_records, opts, graph_config) do
    entity_extractor = resolve_entity_extractor(opts, graph_config)
    relationship_extractor = resolve_relationship_extractor(opts, graph_config)

    Enum.reduce(chunk_records, {[], [], []}, fn chunk, {ent_acc, ment_acc, rel_acc} ->
      extract_graph_data_from_chunk(chunk, entity_extractor, relationship_extractor, ent_acc, ment_acc, rel_acc)
    end)
  end

  defp resolve_entity_extractor(opts, graph_config) do
    llm = opts[:llm] || Application.get_env(:arcana, :llm)
    extractor = Keyword.get(opts, :entity_extractor) || graph_config[:entity_extractor]
    normalize_entity_extractor(extractor, llm)
  end

  defp normalize_entity_extractor(nil, _llm), do: {Arcana.Graph.EntityExtractor.NER, []}
  defp normalize_entity_extractor(:ner, _llm), do: {Arcana.Graph.EntityExtractor.NER, []}
  defp normalize_entity_extractor({module, opts}, llm), do: {module, maybe_inject_llm(opts, llm)}
  defp normalize_entity_extractor(fun, _llm) when is_function(fun, 2), do: fun
  defp normalize_entity_extractor(module, llm) when is_atom(module), do: {module, maybe_inject_llm([], llm)}

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

  # Combined extractor (single LLM call per chunk) - takes priority over separate extractors
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

  defp extract_graph_data_combined(chunk, extractor, ent_acc, ment_acc, rel_acc) do
    case GraphExtractor.extract(extractor, chunk.text) do
      {:ok, %{entities: entities, relationships: relationships}} ->
        # Track mentions (entity name -> chunk id)
        new_mentions =
          Enum.map(entities, fn entity ->
            %{
              entity_name: entity.name,
              chunk_id: chunk.id,
              span_start: entity[:span_start],
              span_end: entity[:span_end]
            }
          end)

        {ent_acc ++ entities, ment_acc ++ new_mentions, rel_acc ++ relationships}

      {:error, _reason} ->
        # Continue despite extraction errors
        {ent_acc, ment_acc, rel_acc}
    end
  end

  defp extract_graph_data_from_chunk(
         chunk,
         entity_extractor,
         relationship_extractor,
         ent_acc,
         ment_acc,
         rel_acc
       ) do
    case EntityExtractor.extract(entity_extractor, chunk.text) do
      {:ok, entities} ->
        # Track mentions (entity name -> chunk id)
        new_mentions =
          Enum.map(entities, fn entity ->
            %{
              entity_name: entity.name,
              chunk_id: chunk.id,
              span_start: entity[:span_start],
              span_end: entity[:span_end]
            }
          end)

        # Extract relationships if extractor is configured
        new_relationships =
          case RelationshipExtractor.extract(relationship_extractor, chunk.text, entities) do
            {:ok, rels} -> rels
            {:error, _} -> []
          end

        {ent_acc ++ entities, ment_acc ++ new_mentions, rel_acc ++ new_relationships}

      {:error, _reason} ->
        # Continue despite extraction errors
        {ent_acc, ment_acc, rel_acc}
    end
  end

  defp persist_entities(entities, collection, repo) do
    # Deduplicate by name
    unique_entities =
      entities
      |> Enum.reduce(%{}, fn entity, acc ->
        Map.put_new(acc, entity.name, entity)
      end)
      |> Map.values()

    # Upsert each entity and build name -> id mapping
    unique_entities
    |> Enum.reduce(%{}, fn entity, id_map ->
      entity_record = upsert_entity(entity, collection, repo)
      Map.put(id_map, entity.name, entity_record.id)
    end)
  end

  defp upsert_entity(entity, collection, repo) do
    import Ecto.Query

    # Check if entity exists
    existing =
      repo.one(
        from(e in Entity,
          where: e.name == ^entity.name and e.collection_id == ^collection.id
        )
      )

    case existing do
      nil ->
        # Insert new entity
        %Entity{}
        |> Entity.changeset(%{
          name: entity.name,
          type: entity.type,
          description: entity[:description],
          collection_id: collection.id
        })
        |> repo.insert!()

      entity_record ->
        # Return existing entity
        entity_record
    end
  end

  defp persist_entity_mentions(mentions, entity_id_map, repo) do
    mentions
    |> Enum.each(fn mention ->
      entity_id = Map.get(entity_id_map, mention.entity_name)

      if entity_id do
        %EntityMention{}
        |> EntityMention.changeset(%{
          entity_id: entity_id,
          chunk_id: mention.chunk_id,
          span_start: mention[:span_start],
          span_end: mention[:span_end]
        })
        |> repo.insert!()
      end
    end)
  end

  defp persist_relationships(relationships, entity_id_map, repo) do
    relationships
    |> Enum.each(fn rel ->
      source_id = Map.get(entity_id_map, rel.source)
      target_id = Map.get(entity_id_map, rel.target)

      if source_id && target_id do
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: source_id,
          target_id: target_id,
          type: rel.type,
          description: rel[:description],
          strength: rel[:strength]
        })
        |> repo.insert!()
      end
    end)
  end
end
