defmodule Arcana.Ingest do
  @moduledoc """
  Document ingestion for Arcana.

  Handles chunking, embedding, and storing documents with optional
  GraphRAG entity/relationship extraction.
  """

  require Logger

  alias Arcana.{Chunk, Chunker, Collection, Document, Embedder, Parser}
  alias Arcana.Graph.GraphStore

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

  Handles plain text, markdown, and PDF natively, plus any format with a
  parser registered under `config :arcana, :file_parsers` — see
  `Arcana.Parser` for resolution and `Arcana.FileParser` for the
  behaviour. The document's `content_type` comes from the resolved
  parser.

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

  ## Chunk metadata

  Every chunk stores the `"start_byte"`/`"end_byte"` range it occupies in
  the extracted text. When the parser also reports page positions (the
  built-in PDF parser does), chunks additionally carry `"page_start"` and
  `"page_end"`, so `Arcana.search/2` results can cite a page:

      [result | _] = Arcana.search("refund policy", repo: Repo)
      result.metadata["page_start"]
      #=> 4

  """
  def ingest_file(path, opts) when is_binary(path) do
    case Parser.parse_file(path) do
      {:ok, text, parse_meta} ->
        opts
        |> Keyword.put(:file_path, path)
        |> Keyword.put(:content_type, Parser.content_type_for(path))
        |> Keyword.put(:parse_meta, parse_meta)
        |> then(&ingest_with_file_attrs(text, &1))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Ingests in-memory bytes, parsing them the same way `ingest_file/2`
  parses a file on disk.

  `:filename` is required: its extension picks the parser and its value
  is stored as the document's `file_path` for provenance. Nothing is
  written to disk.

  ## Options

    * `:filename` - Name the bytes came from, e.g. `"report.docx"` (required)
    * `:repo` - The Ecto repo to use (required)
    * `:source_id` - An optional identifier for grouping/filtering
    * `:metadata` - Optional map of metadata to store with the document
    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)
    * `:collection` - Collection name to organize the document (default: "default")

  ## Parsers that need a path

  A parser only handles binaries when it says so via
  `c:Arcana.FileParser.supports_binary?/0`. The built-in PDF parser
  shells out to `pdftotext` and needs a real file, so ingesting PDF bytes
  returns `{:error, {:binary_unsupported, Arcana.FileParser.PDF.Poppler}}`
  — write them to a temp file and use `ingest_file/2` instead.

  A parser that is *also* unavailable reports that instead, since a retry
  through `ingest_file/2` would fail just the same: with `pdftotext`
  missing, PDF bytes come back as `{:error, :poppler_not_available}`.
  """
  def ingest_binary(binary, opts) when is_binary(binary) do
    filename =
      Keyword.get(opts, :filename) ||
        raise ArgumentError, "ingest_binary/2 requires a :filename to route on and record"

    case Parser.parse_binary(binary, filename) do
      {:ok, text, parse_meta} ->
        opts
        |> Keyword.delete(:filename)
        |> Keyword.put(:file_path, filename)
        |> Keyword.put(:content_type, Parser.content_type_for(filename))
        |> Keyword.put(:parse_meta, parse_meta)
        |> then(&ingest_with_file_attrs(text, &1))

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
    build_graph_or_fail_document(document, chunk_records, collection, repo, opts)

    if Keyword.get(opts, :replace, false) do
      with {:ok, document} <- finalize_replace(document, chunk_records, repo) do
        sweep_graph_orphans(document.collection_id, repo, opts)
        {:ok, document}
      end
    else
      document
      |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
      |> repo.update()
    end
  end

  # A graph build blows up on failure (extraction errors that come back as
  # {:error, reason} are swallowed per chunk, store failures and anything
  # the extractor raises are not). Mark the document :failed before it
  # escapes, the way the embedding path does, so a crashed build can't
  # leave a document stuck in :processing with chunks attached.
  # The already-persisted graph data of earlier chunks stays put — see
  # Arcana.Graph.build_and_persist/4, no caller treats a failed build as
  # having left the graph untouched.
  #
  # `catch` rather than `rescue`: an extractor or store is just as free to
  # throw or exit (a GenServer.call timeout exits) as to raise, and each
  # strands the document the same way. Arcana.Graph turns the extractors'
  # in-task failures back into caller-side ones so they reach here at all.
  defp build_graph_or_fail_document(document, chunk_records, collection, repo, opts) do
    maybe_build_graph(chunk_records, collection, repo, opts)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      document
      |> Document.changeset(%{status: :failed})
      |> repo.update()

      :erlang.raise(kind, reason, stacktrace)
  end

  # The replaced predecessors' chunks cascade away with them, which can
  # strand zero-mention entities; sweep them like Arcana.delete/2 does.
  # Unlike delete/2 a failed sweep doesn't fail the call: the new document
  # is already committed, and returning an error here would push the
  # caller into redoing the whole (LLM-priced) ingest over a cleanup
  # problem. Log it and leave the orphans for the next sweep.
  defp sweep_graph_orphans(collection_id, repo, opts) do
    case GraphStore.maybe_sweep_orphans(collection_id, repo, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Arcana: graph orphan sweep failed for collection #{collection_id}: #{inspect(reason)}"
        )

        :ok
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
            metadata: Chunker.metadata_for(chunk),
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
      chunker_config: chunker_config,
      pages: Keyword.get(opts, :parse_meta, %{})[:pages]
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

    chunks =
      attrs.chunker_config
      |> Chunker.chunk(text, attrs.chunk_opts)
      |> attach_pages(attrs.pages)

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

  # Parsers that report page positions (see `Arcana.FileParser`) give
  # byte ranges into the extracted text; the chunker reports byte ranges
  # for each chunk. Intersecting the two turns "chunk 7" into "pages
  # 3-4", which is what a citation actually needs. A chunk straddling a
  # page break reports different start and end pages.
  #
  # No pages, or a chunker that doesn't report offsets, leaves chunks
  # untouched rather than guessing.
  # Offsets are read straight out of `Arcana.Chunker.metadata_for/1` — the
  # very map that gets stored — instead of re-deriving the chunker's key
  # shape here. `Arcana.Chunker` accepts them under `:metadata` or as
  # top-level extras, with atom or string keys, and declared entries win
  # over extras; going through metadata_for/1 makes those rules agree by
  # construction rather than by two implementations staying in step.
  # Deriving pages from anything else would cite an offset nobody can see
  # in the stored chunk.
  defp attach_pages(chunks, pages) when is_list(pages) and pages != [] do
    Enum.map(chunks, fn chunk ->
      stored = Chunker.metadata_for(chunk)

      case {stored["start_byte"], stored["end_byte"]} do
        {start_byte, end_byte} when is_integer(start_byte) and is_integer(end_byte) ->
          last_byte = max(end_byte - 1, start_byte)

          page_metadata = %{
            "page_start" => page_at(pages, start_byte),
            "page_end" => page_at(pages, last_byte)
          }

          Map.put(chunk, :metadata, Map.merge(declared_metadata(chunk), page_metadata))

        _ ->
          chunk
      end
    end)
  end

  defp attach_pages(chunks, _pages), do: chunks

  # metadata_for/1 takes a keyword list under `:metadata` in stride
  # (`Map.new/1` accepts one), so merging the pages back in has to too.
  # metadata_for/1 reaches for `||`, so a falsy :metadata is simply absent
  # there. Raising here instead would put the whole ingest on its failure
  # path over a key the storage side shrugs at.
  defp declared_metadata(chunk) do
    case Map.get(chunk, :metadata) do
      falsy when falsy in [nil, false] -> %{}
      map when is_map(map) -> map
      list when is_list(list) -> Map.new(list)
    end
  end

  # Pages that trimming emptied out have start == end and can't contain
  # anything, so they never match; a byte past the last page's end (the
  # chunker counts a trailing newline the parser trimmed, say) falls back
  # to the last page that starts at or before it.
  defp page_at(pages, byte) do
    page =
      Enum.find(pages, fn page -> byte >= page.start and byte < page.end end) ||
        pages |> Enum.filter(&(&1.start <= byte)) |> List.last() ||
        List.first(pages)

    page.number
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

  defp parse_collection_opt(name) when is_binary(name), do: {name, nil}
  defp parse_collection_opt(%{name: name, description: desc}), do: {name, desc}
  defp parse_collection_opt(%{name: name}), do: {name, nil}
end
