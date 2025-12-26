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

  alias Arcana.{Chunk, Chunker, Document}
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

  ## Examples

      {:ok, doc} = Arcana.ingest("Hello world", repo: MyApp.Repo)
      {:ok, doc} = Arcana.ingest("Hello", repo: MyApp.Repo, source_id: "doc-123")

  """
  def ingest(text, opts) when is_binary(text) do
    repo = Keyword.fetch!(opts, :repo)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap])

    # Create document
    {:ok, document} =
      %Document{}
      |> Document.changeset(%{
        content: text,
        source_id: source_id,
        metadata: metadata,
        status: :processing
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

  ## Examples

      results = Arcana.search("functional programming", repo: MyApp.Repo)
      results = Arcana.search("query", repo: MyApp.Repo, limit: 5, source_id: "doc-123")
      results = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)

  """
  def search(query, opts) when is_binary(query) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)
    mode = Keyword.get(opts, :mode, :semantic)
    rewriter = Keyword.get(opts, :rewriter)

    unless mode in @valid_modes do
      raise ArgumentError, "invalid search mode: #{inspect(mode)}. Must be one of #{inspect(@valid_modes)}"
    end

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

    do_search(mode, search_query, repo, limit, source_id, threshold)
  end

  defp do_search(:semantic, query, repo, limit, source_id, threshold) do
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
      if source_id do
        from([c, d] in base_query, where: d.source_id == ^source_id)
      else
        base_query
      end

    repo.all(final_query)
  end

  defp do_search(:fulltext, query, repo, limit, source_id, _threshold) do
    tsquery = to_tsquery(query)

    base_query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where: fragment("to_tsvector('english', ?) @@ to_tsquery('english', ?)", c.text, ^tsquery),
        select: %{
          id: c.id,
          text: c.text,
          document_id: c.document_id,
          chunk_index: c.chunk_index,
          score: fragment("ts_rank(to_tsvector('english', ?), to_tsquery('english', ?))", c.text, ^tsquery)
        },
        order_by: [desc: fragment("ts_rank(to_tsvector('english', ?), to_tsquery('english', ?))", c.text, ^tsquery)],
        limit: ^limit
      )

    final_query =
      if source_id do
        from([c, d] in base_query, where: d.source_id == ^source_id)
      else
        base_query
      end

    repo.all(final_query)
  end

  defp do_search(:hybrid, query, repo, limit, source_id, threshold) do
    # Get results from both methods
    semantic_results = do_search(:semantic, query, repo, limit * 2, source_id, threshold)
    fulltext_results = do_search(:fulltext, query, repo, limit * 2, source_id, threshold)

    # Combine using Reciprocal Rank Fusion (RRF)
    rrf_combine(semantic_results, fulltext_results, limit)
  end

  defp to_tsquery(query) do
    query
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" & ")
  end

  defp rrf_combine(list1, list2, limit, k \\ 60) do
    # RRF formula: score = sum(1 / (k + rank))
    scores1 = list1 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)
    scores2 = list2 |> Enum.with_index(1) |> Map.new(fn {item, rank} -> {item.id, 1 / (k + rank)} end)

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
    * `:llm` - A function that takes (prompt, context) and returns {:ok, answer} (required)
    * `:limit` - Maximum number of context chunks to retrieve (default: 5)
    * `:source_id` - Filter context to a specific source
    * `:threshold` - Minimum similarity score for context (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`

  ## Examples

      llm_fn = fn prompt, context -> {:ok, "Generated answer"} end
      {:ok, answer} = Arcana.ask("What is the capital?", repo: MyApp.Repo, llm: llm_fn)

  """
  def ask(question, opts) when is_binary(question) do
    case Keyword.get(opts, :llm) do
      nil ->
        {:error, :no_llm_configured}

      llm_fn when is_function(llm_fn, 2) ->
        search_opts =
          opts
          |> Keyword.take([:repo, :limit, :source_id, :threshold, :mode])
          |> Keyword.put_new(:limit, 5)

        context = search(question, search_opts)
        llm_fn.(question, context)
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
    repo = Keyword.fetch!(opts, :repo)

    case repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        repo.delete!(document)
        :ok
    end
  end
end
