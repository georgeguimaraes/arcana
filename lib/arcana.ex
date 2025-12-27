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

  alias Arcana.{Chunk, Chunker, Collection, Document, LLM, Parser}
  alias Arcana.Embeddings.Serving

  import Ecto.Query

  @doc """
  Ingests text content, creating a document with embedded chunks.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name to organize the document (default: "default")

  ## Examples

      {:ok, doc} = Arcana.ingest("Hello world", repo: MyApp.Repo)
      {:ok, doc} = Arcana.ingest("Hello", repo: MyApp.Repo, source_id: "doc-123")
      {:ok, doc} = Arcana.ingest("Hello", repo: MyApp.Repo, collection: "products")

  """
  def ingest(text, opts) when is_binary(text) do
    opts = merge_defaults(opts)
    repo = Keyword.fetch!(opts, :repo)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    collection_name = Keyword.get(opts, :collection, "default")
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap])

    start_metadata = %{
      text: text,
      repo: repo,
      collection: collection_name
    }

    :telemetry.span([:arcana, :ingest], start_metadata, fn ->
      # Get or create collection
      {:ok, collection} = Collection.get_or_create(collection_name, repo)

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
      chunk_records =
        chunks
        |> Enum.map(fn chunk ->
          embedding = Serving.embed(chunk.text)

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
    opts = merge_defaults(opts)
    repo = Keyword.fetch!(opts, :repo)
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
    chunk_records =
      chunks
      |> Enum.map(fn chunk ->
        embedding = Serving.embed(chunk.text)

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

    * `:repo` - The Ecto repo to use (required)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:threshold` - Minimum similarity score (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:collection` - Filter results to a specific collection by name

  ## Examples

      results = Arcana.search("functional programming", repo: MyApp.Repo)
      results = Arcana.search("query", repo: MyApp.Repo, limit: 5, source_id: "doc-123")
      results = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)
      results = Arcana.search("query", repo: MyApp.Repo, collection: "products")

  """
  def search(query, opts) when is_binary(query) do
    opts = merge_defaults(opts)
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)
    mode = Keyword.get(opts, :mode, :semantic)
    rewriter = Keyword.get(opts, :rewriter)
    collection_name = Keyword.get(opts, :collection)

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
      # Apply query rewriting if configured
      search_query =
        if rewriter do
          case rewrite_query(query, rewriter: rewriter) do
            {:ok, rewritten} -> rewritten
            {:error, _} -> query
          end
        else
          query
        end

      # Get collection_id if filtering by collection
      collection_id =
        if collection_name do
          case repo.get_by(Collection, name: collection_name) do
            nil -> nil
            collection -> collection.id
          end
        end

      results = do_search(mode, search_query, repo, limit, source_id, threshold, collection_id)

      stop_metadata = %{
        results: results,
        result_count: length(results)
      }

      {results, stop_metadata}
    end)
  end

  defp do_search(:semantic, query, repo, limit, source_id, threshold, collection_id) do
    query_embedding = Serving.embed(query)

    base_query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        select: %{
          id: c.id,
          text: c.text,
          document_id: c.document_id,
          chunk_index: c.chunk_index,
          score: fragment("1 - (? <=> ?)", c.embedding, ^query_embedding)
        },
        where: fragment("1 - (? <=> ?) > ?", c.embedding, ^query_embedding, ^threshold),
        order_by: fragment("? <=> ?", c.embedding, ^query_embedding),
        limit: ^limit
      )

    final_query =
      base_query
      |> maybe_filter_source_id(source_id)
      |> maybe_filter_collection_id(collection_id)

    repo.all(final_query)
  end

  defp do_search(:fulltext, query, repo, limit, source_id, _threshold, collection_id) do
    tsquery = to_tsquery(query)

    base_query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where:
          fragment("to_tsvector('english', ?) @@ to_tsquery('english', ?)", c.text, ^tsquery),
        select: %{
          id: c.id,
          text: c.text,
          document_id: c.document_id,
          chunk_index: c.chunk_index,
          score:
            fragment(
              "ts_rank(to_tsvector('english', ?), to_tsquery('english', ?))",
              c.text,
              ^tsquery
            )
        },
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('english', ?), to_tsquery('english', ?))",
              c.text,
              ^tsquery
            )
        ],
        limit: ^limit
      )

    final_query =
      base_query
      |> maybe_filter_source_id(source_id)
      |> maybe_filter_collection_id(collection_id)

    repo.all(final_query)
  end

  defp do_search(:hybrid, query, repo, limit, source_id, threshold, collection_id) do
    # Get results from both methods
    semantic_results =
      do_search(:semantic, query, repo, limit * 2, source_id, threshold, collection_id)

    fulltext_results =
      do_search(:fulltext, query, repo, limit * 2, source_id, threshold, collection_id)

    # Combine using Reciprocal Rank Fusion (RRF)
    rrf_combine(semantic_results, fulltext_results, limit)
  end

  defp to_tsquery(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" & ")
  end

  defp maybe_filter_source_id(query, nil), do: query

  defp maybe_filter_source_id(query, source_id) do
    from([c, d] in query, where: d.source_id == ^source_id)
  end

  defp maybe_filter_collection_id(query, nil), do: query

  defp maybe_filter_collection_id(query, collection_id) do
    from([c, d] in query, where: d.collection_id == ^collection_id)
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

  ## Examples

      # Using an anonymous function
      llm = fn prompt, context -> {:ok, "Generated answer"} end
      {:ok, answer} = Arcana.ask("What is the capital?", repo: MyApp.Repo, llm: llm)

      # Using a LangChain model (when langchain is installed)
      llm = LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"})
      {:ok, answer} = Arcana.ask("What is the capital?", repo: MyApp.Repo, llm: llm)

  """
  def ask(question, opts) when is_binary(question) do
    opts = merge_defaults(opts)
    repo = Keyword.get(opts, :repo)

    case Keyword.get(opts, :llm) do
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
            |> Keyword.take([:repo, :limit, :source_id, :threshold, :mode])
            |> Keyword.put_new(:limit, 5)

          context = search(question, search_opts)
          result = LLM.complete(llm, question, context)

          stop_metadata =
            case result do
              {:ok, answer} -> %{answer: answer, context_count: length(context)}
              {:error, _} -> %{context_count: length(context)}
            end

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
    opts = merge_defaults(opts)
    repo = Keyword.fetch!(opts, :repo)

    case repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        repo.delete!(document)
        :ok
    end
  end

  # Merges application config defaults with provided options.
  # Options passed explicitly take precedence over config.
  defp merge_defaults(opts) do
    defaults =
      [:repo, :llm]
      |> Enum.map(fn key -> {key, Application.get_env(:arcana, key)} end)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Keyword.merge(defaults, opts)
  end
end
