defmodule Arcana.Ingest do
  @moduledoc """
  Document ingestion for Arcana.

  Handles chunking, embedding, and storing documents with optional
  GraphRAG entity/relationship extraction.
  """

  alias Arcana.{Chunk, Chunker, Collection, Document, Embedder, Parser}

  @doc """
  Ingests text content, creating a document with embedded chunks.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name (string) or map with name and description (default: "default")
    * `:graph` - Enable GraphRAG extraction (default: from config)

  """
  def ingest(text, opts) when is_binary(text) do
    repo = require_repo!(opts)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})

    {collection_name, collection_description} =
      parse_collection_opt(Keyword.get(opts, :collection, "default"))

    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunker_config = Arcana.Config.resolve_chunker(opts)

    start_metadata = %{
      text: text,
      repo: repo,
      collection: collection_name
    }

    :telemetry.span([:arcana, :ingest], start_metadata, fn ->
      case resolve_collection(collection_name, collection_description, repo, opts) do
        {:ok, collection} ->
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

          chunks = Chunker.chunk(chunker_config, text, chunk_opts)
          result = embed_and_store_chunks(chunks, document, repo)

          case result do
            {:ok, chunk_records} ->
              finalize_ingest(document, chunk_records, collection, repo, opts)

            {:error, reason} ->
              {{:error, reason}, %{error: reason}}
          end

        {:error, reason} ->
          {{:error, reason}, %{error: reason}}
      end
    end)
  end

  @doc """
  Ingests a file, parsing its content and creating a document with embedded chunks.

  Supports multiple file formats including plain text, markdown, and PDF.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name to organize the document (default: "default")

  """
  def ingest_file(path, opts) when is_binary(path) do
    case Parser.parse(path) do
      {:ok, text} ->
        content_type = content_type_for_path(path)

        opts =
          opts
          |> Keyword.put(:file_path, path)
          |> Keyword.put(:content_type, content_type)

        ingest_with_file_attrs(text, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp require_repo!(opts), do: Arcana.Config.require_repo!(opts)

  defp finalize_ingest(document, chunk_records, collection, repo, opts) do
    maybe_build_graph(chunk_records, collection, repo, opts)

    {:ok, document} =
      document
      |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
      |> repo.update()

    {{:ok, document}, %{document: document, chunk_count: length(chunk_records)}}
  end

  defp maybe_build_graph(chunk_records, collection, repo, opts) do
    if Arcana.Config.graph_enabled?(opts) do
      Arcana.Graph.build_and_persist(chunk_records, collection, repo, opts)
    end
  end

  defp embed_and_store_chunks(chunks, document, repo) do
    emb = Arcana.Config.embedder()

    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      embed_single_chunk(emb, chunk, document, repo, acc)
    end)
  end

  defp embed_single_chunk(emb, chunk, document, repo, acc) do
    case Embedder.embed(emb, chunk.text, intent: :document) do
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

  defp ingest_with_file_attrs(text, opts) do
    repo = require_repo!(opts)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    file_path = Keyword.get(opts, :file_path)
    content_type = Keyword.get(opts, :content_type, "text/plain")
    collection_name = Keyword.get(opts, :collection, "default")
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunker_config = Arcana.Config.resolve_chunker(opts)

    with {:ok, collection} <- resolve_collection(collection_name, nil, repo, opts) do
      do_ingest_with_file_attrs(text, collection, repo, %{
        source_id: source_id,
        metadata: metadata,
        file_path: file_path,
        content_type: content_type,
        chunk_opts: chunk_opts,
        chunker_config: chunker_config
      })
    end
  end

  defp do_ingest_with_file_attrs(text, collection, repo, attrs) do
    {:ok, document} =
      %Document{}
      |> Document.changeset(%{
        content: text,
        source_id: attrs.source_id,
        metadata: attrs.metadata,
        file_path: attrs.file_path,
        content_type: attrs.content_type,
        status: :processing,
        collection_id: collection.id
      })
      |> repo.insert()

    chunks = Chunker.chunk(attrs.chunker_config, text, attrs.chunk_opts)
    result = embed_and_store_chunks(chunks, document, repo)

    case result do
      {:ok, chunk_records} ->
        {:ok, document} =
          document
          |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
          |> repo.update()

        {:ok, document}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Under strict_collections, ingest requires the collection to already
  # exist (create explicitly with Collection.get_or_create/3); otherwise
  # it is created on the fly.
  defp resolve_collection(name, description, repo, opts) do
    if Arcana.Config.strict_collections?(opts) do
      Collection.fetch(name, repo)
    else
      Collection.get_or_create(name, repo, description)
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

  defp parse_collection_opt(name) when is_binary(name), do: {name, nil}
  defp parse_collection_opt(%{name: name, description: desc}), do: {name, desc}
  defp parse_collection_opt(%{name: name}), do: {name, nil}
end
