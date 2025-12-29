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

  alias Arcana.{Chunk, Embedder}

  import Ecto.Query

  @doc """
  Re-embeds all chunks using the current embedding configuration.

  This is useful when switching embedding models or updating to a new version.

  ## Options

    * `:batch_size` - Number of chunks to process at once (default: 50)
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

    # Get total count
    total = repo.aggregate(Chunk, :count)

    if total == 0 do
      {:ok, %{reembedded: 0, total: 0}}
    else
      # Process in batches
      chunks_query = from(c in Chunk, order_by: c.id, select: [:id, :text])

      result =
        chunks_query
        |> repo.stream(max_rows: batch_size)
        |> Stream.with_index(1)
        |> Enum.reduce({:ok, 0}, fn
          {chunk, index}, {:ok, count} ->
            reembed_chunk(chunk, embedder, repo, progress_fn, index, total, count)

          _chunk, error ->
            error
        end)

      case result do
        {:ok, count} -> {:ok, %{reembedded: count, total: total}}
        error -> error
      end
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

      {Arcana.Embedder.Zai, opts} ->
        dims = Keyword.get(opts, :dimensions, 1536)
        %{type: :zai, model: "embedding-3", dimensions: dims}

      {Arcana.Embedder.Custom, _opts} ->
        %{type: :custom, dimensions: dimensions}

      {module, _opts} ->
        %{type: :custom, module: module, dimensions: dimensions}
    end
  end

  defp reembed_chunk(chunk, embedder, repo, progress_fn, index, total, count) do
    case Embedder.embed(embedder, chunk.text) do
      {:ok, embedding} ->
        repo.update_all(
          from(c in Chunk, where: c.id == ^chunk.id),
          set: [embedding: embedding, updated_at: DateTime.utc_now()]
        )

        progress_fn.(index, total)
        {:ok, count + 1}

      {:error, reason} ->
        {:error, {:embed_failed, chunk.id, reason}}
    end
  end
end
