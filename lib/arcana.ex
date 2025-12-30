defmodule Arcana do
  @moduledoc """
  RAG (Retrieval Augmented Generation) library for Elixir.

  Arcana provides document ingestion, embedding, and vector search
  capabilities that you can embed into any Phoenix/Ecto application.

  ## Usage

      # Ingest a document
      {:ok, document} = Arcana.ingest("Your text content", repo: MyApp.Repo)

      # Search for relevant chunks
      results = Arcana.search("your query", repo: MyApp.Repo)

      # Delete a document
      :ok = Arcana.delete(document.id, repo: MyApp.Repo)

  """

  alias Arcana.{Chunk, Chunker, Collection, Document, Embedder, LLM, Parser, VectorStore}

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
      reranker: Application.get_env(:arcana, :reranker, Arcana.Reranker.LLM)
    }
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

    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap])

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
      chunks = Chunker.chunk(text, chunk_opts)

      # Embed and store chunks
      emb = embedder()

      chunk_records =
        chunks
        |> Enum.map(fn chunk ->
          {:ok, embedding} = Embedder.embed(emb, chunk.text)

          %Chunk{}
          |> Chunk.changeset(%{
            text: chunk.text,
            embedding: embedding,
            chunk_index: chunk.chunk_index,
            token_count: chunk.token_count,
            document_id: document.id
          })
          |> repo.insert!()
        end)

      # Update document status
      {:ok, document} =
        document
        |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
        |> repo.update()

      stop_metadata = %{
        document: document,
        chunk_count: length(chunk_records)
      }

      {{:ok, document}, stop_metadata}
    end)
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
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap])

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
    chunks = Chunker.chunk(text, chunk_opts)

    # Embed and store chunks
    emb = embedder()

    chunk_records =
      chunks
      |> Enum.map(fn chunk ->
        {:ok, embedding} = Embedder.embed(emb, chunk.text)

        %Chunk{}
        |> Chunk.changeset(%{
          text: chunk.text,
          embedding: embedding,
          chunk_index: chunk.chunk_index,
          token_count: chunk.token_count,
          document_id: document.id
        })
        |> repo.insert!()
      end)

    # Update document status
    {:ok, document} =
      document
      |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
      |> repo.update()

    {:ok, document}
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

  Returns a list of maps containing chunk information and similarity scores.

  ## Options

    * `:repo` - The Ecto repo to use (required for pgvector backend)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:threshold` - Minimum similarity score (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:collection` - Filter results to a specific collection by name
    * `:vector_store` - Override the configured vector store backend. See `Arcana.VectorStore`

  ## Vector Store Backend

  For `:semantic` mode, search uses the globally configured vector store
  (`config :arcana, vector_store: :pgvector | :memory`). This allows using
  the in-memory backend for testing or smaller RAG applications.

  For `:fulltext` and `:hybrid` modes, pgvector is always used since these
  require PostgreSQL full-text search capabilities.

  You can override the vector store per-call:

      # Use a specific memory server
      Arcana.search("query", vector_store: {:memory, pid: memory_pid})

      # Use a specific repo with pgvector
      Arcana.search("query", vector_store: {:pgvector, repo: OtherRepo})

  ## Examples

      results = Arcana.search("functional programming", repo: MyApp.Repo)
      results = Arcana.search("query", repo: MyApp.Repo, limit: 5, source_id: "doc-123")
      results = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)
      results = Arcana.search("query", repo: MyApp.Repo, collection: "products")

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

      # Search each collection and combine results
      results =
        collections
        |> Enum.flat_map(fn collection_name ->
          do_search(mode, search_query, %{
            repo: repo,
            limit: limit,
            source_id: source_id,
            threshold: threshold,
            collection: collection_name,
            vector_store: vector_store_opt
          })
        end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(limit)

      stop_metadata = %{
        results: results,
        result_count: length(results)
      }

      {results, stop_metadata}
    end)
  end

  defp do_search(:semantic, query, params) do
    {:ok, query_embedding} = Embedder.embed(embedder(), query)

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

  defp do_search(:hybrid, query, params) do
    # Get results from both methods
    semantic_params = %{params | limit: params.limit * 2}
    fulltext_params = %{params | limit: params.limit * 2}

    semantic_results = do_search(:semantic, query, semantic_params)
    fulltext_results = do_search(:fulltext, query, fulltext_params)

    # Combine using Reciprocal Rank Fusion (RRF)
    rrf_combine(semantic_results, fulltext_results, params.limit)
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

    case llm do
      nil ->
        {:error, :no_llm_configured}

      llm ->
        start_metadata = %{
          question: question,
          repo: repo
        }

        :telemetry.span([:arcana, :ask], start_metadata, fn ->
          search_opts =
            opts
            |> Keyword.take([
              :repo,
              :limit,
              :source_id,
              :threshold,
              :mode,
              :collection,
              :collections
            ])
            |> Keyword.put_new(:limit, 5)

          context = search(question, search_opts)
          prompt_fn = Keyword.get(opts, :prompt, &default_ask_prompt/2)
          llm_opts = [system_prompt: prompt_fn.(question, context)]

          result = do_ask_llm(llm, question, context, llm_opts)
          stop_metadata = ask_stop_metadata(result, context)

          {result, stop_metadata}
        end)
    end
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
end
