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

  alias Arcana.{Chunk, Chunker, Collection, Document, Embedder}
  alias Arcana.Graph.GraphStore

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
    collection_filter = Keyword.get(opts, :collection)

    embedder = Arcana.embedder()
    collection_id = get_collection_id(repo, collection_filter)

    # First, rechunk documents that have no chunks
    docs_without_chunks = fetch_docs_without_chunks(repo, collection_id)

    rechunked =
      if docs_without_chunks != [] do
        rechunk_documents(docs_without_chunks, embedder, repo, progress_fn)
      else
        0
      end

    # Then re-embed existing chunks
    {total_chunks, reembedded} =
      reembed_filtered_chunks(repo, embedder, batch_size, progress_fn, collection_id)

    {:ok, %{rechunked_documents: rechunked, reembedded: reembedded, total_chunks: total_chunks}}
  end

  defp get_collection_id(_repo, nil), do: nil

  defp get_collection_id(repo, collection_name) when is_binary(collection_name) do
    case repo.one(from(c in Collection, where: c.name == ^collection_name, select: c.id)) do
      nil -> nil
      id -> id
    end
  end

  defp fetch_docs_without_chunks(repo, nil) do
    repo.all(from(d in Document, where: d.chunk_count == 0 or d.status == :pending))
  end

  defp fetch_docs_without_chunks(repo, collection_id) do
    repo.all(
      from(d in Document,
        where: d.collection_id == ^collection_id and (d.chunk_count == 0 or d.status == :pending)
      )
    )
  end

  defp reembed_filtered_chunks(repo, embedder, batch_size, progress_fn, nil) do
    total_chunks = repo.aggregate(Chunk, :count)

    reembedded =
      if total_chunks > 0 do
        reembed_chunks(repo, embedder, batch_size, progress_fn, total_chunks)
      else
        0
      end

    {total_chunks, reembedded}
  end

  defp reembed_filtered_chunks(repo, embedder, batch_size, progress_fn, collection_id) do
    chunks_query =
      from(c in Chunk,
        join: d in Document,
        on: d.id == c.document_id,
        where: d.collection_id == ^collection_id,
        order_by: c.id,
        select: [:id, :text]
      )

    total_chunks = repo.aggregate(chunks_query, :count)

    reembedded =
      if total_chunks > 0 do
        reembed_chunks_from_query(
          repo,
          embedder,
          batch_size,
          progress_fn,
          total_chunks,
          chunks_query
        )
      else
        0
      end

    {total_chunks, reembedded}
  end

  defp reembed_chunks_from_query(repo, embedder, batch_size, progress_fn, total, chunks_query) do
    repo.transaction(fn ->
      chunks_query
      |> repo.stream(max_rows: batch_size)
      |> Stream.with_index(1)
      |> Enum.reduce(0, fn {chunk, index}, count ->
        reembed_single_chunk(repo, embedder, chunk, index, total, progress_fn, count)
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise reason
    end
  end

  defp rechunk_documents(documents, embedder, repo, progress_fn) do
    total = length(documents)
    chunker = Arcana.chunker()

    documents
    |> Enum.with_index(1)
    |> Enum.reduce(0, fn {doc, index}, count ->
      progress_fn.(index, total)

      chunks = Chunker.chunk(chunker, doc.content)

      Enum.each(chunks, fn chunk ->
        {:ok, embedding} = Embedder.embed(embedder, chunk.text, intent: :document)

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
        reembed_single_chunk(repo, embedder, chunk, index, total, progress_fn, count)
      end)
    end)
    |> case do
      {:ok, count} -> count
      {:error, reason} -> raise reason
    end
  end

  defp reembed_single_chunk(repo, embedder, chunk, index, total, progress_fn, count) do
    case Embedder.embed(embedder, chunk.text, intent: :document) do
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

  @doc """
  Rebuilds the knowledge graph for documents.

  This clears existing graph data (entities, relationships, mentions) and
  re-extracts from all chunks using the current graph extractor configuration.

  Use this when:
  - You've changed the graph extractor configuration
  - You've enabled relationship extraction after initial ingest
  - You want to regenerate entity/relationship data

  ## Options

    * `:collection` - Filter to a specific collection by name (default: all collections)
    * `:batch_size` - Number of chunks to process per collection batch (default: 50)
    * `:progress` - Function to call with progress updates `fn current, total -> :ok end`

  ## Examples

      # Basic usage - all collections
      Arcana.Maintenance.rebuild_graph(MyApp.Repo)

      # Single collection
      Arcana.Maintenance.rebuild_graph(MyApp.Repo, collection: "test-graphrag-3")

      # With progress callback
      Arcana.Maintenance.rebuild_graph(MyApp.Repo,
        progress: fn current, total ->
          IO.puts("Progress: \#{current}/\#{total}")
        end
      )

  """
  def rebuild_graph(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)

    # Get collections (optionally filtered)
    collections = fetch_collections(repo, collection_filter)

    if collections == [] do
      {:ok, %{collections: 0, entities: 0, relationships: 0}}
    else
      total_collections = length(collections)

      results =
        rebuild_graph_for_collections(collections, repo, opts, progress_fn, total_collections)

      total_entities = Enum.sum(Enum.map(results, & &1.entities))
      total_relationships = Enum.sum(Enum.map(results, & &1.relationships))

      {:ok,
       %{
         collections: total_collections,
         entities: total_entities,
         relationships: total_relationships
       }}
    end
  end

  defp rebuild_graph_for_collections(collections, repo, opts, progress_fn, total) do
    collections
    |> Enum.with_index(1)
    |> Enum.map(fn {collection, index} ->
      progress_fn.(index, total)
      rebuild_graph_for_collection(collection, repo, opts)
    end)
  end

  defp rebuild_graph_for_collection(collection, repo, opts) do
    # Clear existing graph data for this collection
    :ok = GraphStore.delete_by_collection(collection.id, repo: repo)

    # Get all chunks for this collection
    chunk_records =
      repo.all(
        from(c in Chunk,
          join: d in Document,
          on: d.id == c.document_id,
          where: d.collection_id == ^collection.id,
          select: %{id: c.id, text: c.text}
        )
      )

    if chunk_records == [] do
      %{entities: 0, relationships: 0}
    else
      case Arcana.Graph.build_and_persist(chunk_records, collection, repo, opts) do
        {:ok, %{entity_count: entities, relationship_count: relationships}} ->
          %{entities: entities, relationships: relationships}

        {:error, _reason} ->
          %{entities: 0, relationships: 0}
      end
    end
  end

  defp fetch_collections(repo, nil) do
    repo.all(from(c in Collection, select: c))
  end

  defp fetch_collections(repo, collection_name) when is_binary(collection_name) do
    repo.all(from(c in Collection, where: c.name == ^collection_name, select: c))
  end

  @doc """
  Returns info about the current graph configuration.

  ## Examples

      iex> Arcana.Maintenance.graph_info()
      %{enabled: true, extractor: :llm}

  """
  def graph_info do
    config = Arcana.Graph.config()
    graph_opts = Application.get_env(:arcana, :graph, [])

    {extractor_type, extractor_name} =
      cond do
        config[:extractor] || graph_opts[:extractor] ->
          extractor = config[:extractor] || graph_opts[:extractor]
          {:combined, format_extractor_name(extractor)}

        config[:relationship_extractor] || graph_opts[:relationship_extractor] ->
          {:separate, nil}

        true ->
          {:entities_only, nil}
      end

    %{
      enabled: config.enabled,
      extractor_type: extractor_type,
      extractor_name: extractor_name,
      community_levels: config.community_levels,
      resolution: config.resolution
    }
  end

  defp format_extractor_name(nil), do: nil
  defp format_extractor_name(:ner), do: "NER"
  defp format_extractor_name(:llm), do: "LLM"

  defp format_extractor_name({module, _opts}) when is_atom(module) do
    module |> Module.split() |> List.last()
  end

  defp format_extractor_name(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end

  defp format_extractor_name(_other), do: nil
end
