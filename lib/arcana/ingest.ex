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
    * `:replace` - When true, atomically replaces any prior document with the
      same `(collection, source_id)` once the new ingest completes. Requires
      `:source_id`. See "Replacing documents" below.

  ## Replacing documents

  With `replace: true`, `source_id` becomes a stable document identity:
  re-ingesting the same identity supersedes earlier documents instead of
  accumulating next to them. The new document is ingested first and
  predecessors (including `:failed`/`:processing` leftovers from crashed
  attempts) are deleted only after it completes, so the old chunks stay
  searchable until the replacement lands and their rows cascade away with
  the document.

  The swap runs in a transaction under a per-identity advisory lock, so
  callers don't need their own mutex for correctness. If two ingests for the
  same identity run concurrently, the first to complete wins and the other
  returns `{:error, :replaced_by_concurrent_ingest}` (or may fail while
  storing chunks whose document was already replaced).
  """
  def ingest(text, opts) when is_binary(text) do
    repo = require_repo!(opts)
    validate_replace_opts!(opts)
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
              finalize_with_telemetry(document, chunk_records, collection, repo, opts)

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
    * `:graph` - Enable GraphRAG extraction (default: from config)
    * `:replace` - When true, atomically replaces any prior document with the
      same `(collection, source_id)` once the new ingest completes. Requires
      `:source_id`. See "Replacing documents" in `ingest/2`.

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

  defp finalize_with_telemetry(document, chunk_records, collection, repo, opts) do
    case finalize_ingest(document, chunk_records, collection, repo, opts) do
      {:ok, document} ->
        {{:ok, document}, %{document: document, chunk_count: length(chunk_records)}}

      {:error, reason} ->
        {{:error, reason}, %{error: reason}}
    end
  end

  defp finalize_ingest(document, chunk_records, collection, repo, opts) do
    maybe_build_graph(chunk_records, collection, repo, opts)

    if Keyword.get(opts, :replace, false) do
      finalize_replace(document, chunk_records, repo)
    else
      document
      |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
      |> repo.update()
    end
  end

  # The replace swap: delete every other document with the same
  # (collection_id, source_id) — completed predecessors and crashed-attempt
  # leftovers alike (chunks cascade via FK) — then mark the new document
  # completed. Runs under a per-identity transaction-scoped advisory lock so
  # concurrent replaces serialize HERE, at the fast DB-only step, never
  # around chunking/embedding. A run whose document was already deleted by a
  # faster concurrent replace loses cleanly.
  defp finalize_replace(document, chunk_records, repo) do
    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "arcana:replace:#{document.collection_id}:#{document.source_id}"
      ])

      if repo.get(Document, document.id) do
        import Ecto.Query, only: [from: 2]

        repo.delete_all(
          from(d in Document,
            where:
              d.collection_id == ^document.collection_id and
                d.source_id == ^document.source_id and
                d.id != ^document.id
          )
        )

        {:ok, document} =
          document
          |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
          |> repo.update()

        document
      else
        repo.rollback(:replaced_by_concurrent_ingest)
      end
    end)
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
    validate_replace_opts!(opts)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    file_path = Keyword.get(opts, :file_path)
    content_type = Keyword.get(opts, :content_type, "text/plain")
    collection_name = Keyword.get(opts, :collection, "default")
    chunk_opts = Keyword.take(opts, [:chunk_size, :chunk_overlap, :format, :size_unit])
    chunker_config = Arcana.Config.resolve_chunker(opts)

    attrs = %{
      source_id: source_id,
      metadata: metadata,
      file_path: file_path,
      content_type: content_type,
      chunk_opts: chunk_opts,
      chunker_config: chunker_config
    }

    with {:ok, collection} <- resolve_collection(collection_name, nil, repo, opts) do
      do_ingest_with_file_attrs(text, collection, repo, attrs, opts)
    end
  end

  defp do_ingest_with_file_attrs(text, collection, repo, attrs, opts) do
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

    with {:ok, chunk_records} <- embed_and_store_chunks(chunks, document, repo) do
      finalize_ingest(document, chunk_records, collection, repo, opts)
    end
  end

  defp validate_replace_opts!(opts) do
    source_id = Keyword.get(opts, :source_id)

    if Keyword.get(opts, :replace, false) and (is_nil(source_id) or source_id == "") do
      raise ArgumentError, "replace: true requires a :source_id document identity"
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
