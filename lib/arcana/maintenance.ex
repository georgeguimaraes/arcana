defmodule Arcana.Maintenance do
  @moduledoc """
  Maintenance functions for Arcana.

  These functions are designed to be callable from production environments
  where mix tasks are not available (e.g., releases).

  ## Usage in Production

      # Remote IEx
      iex> Arcana.Maintenance.reembed(MyApp.Repo)

      # Release command
      bin/my_app eval "Arcana.Maintenance.reembed(MyApp.Repo)"

  """

  alias Arcana.{Chunk, Chunker, Document, Embedder}

  import Ecto.Query

  @doc """
  Re-embeds all chunks and rechunks documents that have no chunks.

  This is useful when switching embedding models or after a migration
  that cleared chunks.

  ## Options

    * `:batch_size` - Number of items to process at once (default: 50)
    * `:progress` - Function to call with progress updates `fn current, total -> :ok end`

  ## Examples

      # Basic usage
      Arcana.Maintenance.reembed(MyApp.Repo)

      # With progress callback
      Arcana.Maintenance.reembed(MyApp.Repo,
        batch_size: 100,
        progress: fn current, total ->
          IO.puts("Progress: \#{current}/\#{total}")
        end
      )

  """
  def reembed(repo, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)

    embedder = Arcana.embedder()

    # First, rechunk documents that have no chunks
    docs_without_chunks = repo.all(from d in Document, where: d.chunk_count == 0 or d.status == :pending)

    rechunked =
      if length(docs_without_chunks) > 0 do
        rechunk_documents(docs_without_chunks, embedder, repo, progress_fn)
      else
        0
      end

    # Then re-embed existing chunks
    total_chunks = repo.aggregate(Chunk, :count)

    reembedded =
      if total_chunks > 0 do
        reembed_chunks(repo, embedder, batch_size, progress_fn, total_chunks)
      else
        0
      end

    {:ok, %{rechunked_documents: rechunked, reembedded_chunks: reembedded, total_chunks: total_chunks}}
  end

  defp rechunk_documents(documents, embedder, repo, progress_fn) do
    total = length(documents)

    documents
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {doc, index}, count ->
      progress_fn.(index, total)

      chunks = Chunker.chunk(doc.content, [])

      Enum.each(chunks, fn chunk ->
        {:ok, embedding} = Embedder.embed(embedder, chunk.text)

        %Chunk{}
        |> Chunk.changeset(%{
          text: chunk.text,
          embedding: embedding,
          chunk_index: chunk.chunk_index,
          token_count: chunk.token_count,
          document_id: doc.id
        })
        |> repo.insert!()
      end)

      # Update document status
      doc
      |> Document.changeset(%{status: :completed, chunk_count: length(chunks)})
      |> repo.update!()

      count + 1
    end)
  end

  defp reembed_chunks(repo, embedder, batch_size, progress_fn, total) do
    chunks_query = from(c in Chunk, order_by: c.id, select: [:id, :text])

    repo.transaction(fn ->
      chunks_query
      |> repo.stream(max_rows: batch_size)
      |> Stream.with_index(1)
      |> Enum.reduce(0, fn {chunk, index}, count ->
        case Embedder.embed(embedder, chunk.text) do
          {:ok, embedding} ->
            repo.update_all(
              from(c in Chunk, where: c.id == ^chunk.id),
              set: [embedding: embedding, updated_at: DateTime.utc_now()]
            )

            progress_fn.(index, total)
            count + 1

          {:error, reason} ->
            raise "Failed to embed chunk #{chunk.id}: #{inspect(reason)}"
        end
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Returns the current embedding dimensions.

  Useful for verifying the configured embedder before running migrations.

  ## Examples

      iex> Arcana.Maintenance.embedding_dimensions()
      {:ok, 1536}

  """
  def embedding_dimensions do
    embedder = Arcana.embedder()
    {:ok, Embedder.dimensions(embedder)}
  rescue
    e -> {:error, e}
  end

  @doc """
  Returns info about the current embedding configuration.

  ## Examples

      iex> Arcana.Maintenance.embedding_info()
      %{type: :openai, model: "text-embedding-3-small", dimensions: 1536}

  """
  def embedding_info do
    embedder = Arcana.embedder()
    dimensions = Embedder.dimensions(embedder)

    case embedder do
      {Arcana.Embedder.Local, opts} ->
        model = Keyword.get(opts, :model, "BAAI/bge-small-en-v1.5")
        %{type: :local, model: model, dimensions: dimensions}

      {Arcana.Embedder.OpenAI, opts} ->
        model = Keyword.get(opts, :model, "text-embedding-3-small")
        %{type: :openai, model: model, dimensions: dimensions}

      {Arcana.Embedder.Custom, _opts} ->
        %{type: :custom, dimensions: dimensions}

      {module, _opts} ->
        %{type: :custom, module: module, dimensions: dimensions}
    end
  end
end
