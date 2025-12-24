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

  @doc """
  Searches for chunks similar to the query.

  Returns a list of maps containing chunk information and similarity scores.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:threshold` - Minimum similarity score (default: 0.0)

  ## Examples

      results = Arcana.search("functional programming", repo: MyApp.Repo)
      results = Arcana.search("query", repo: MyApp.Repo, limit: 5, source_id: "doc-123")

  """
  def search(query, opts) when is_binary(query) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    threshold = Keyword.get(opts, :threshold, 0.0)

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
