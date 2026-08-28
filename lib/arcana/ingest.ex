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
    * `:on_chunk_error` - What a chunk that fails to embed does to the rest
      of the document: `:abort` (default) or `:skip`. See "When a chunk
      fails to embed" below.

  ## When a chunk fails to embed

  Every chunk is embedded before anything is written, so a failure never
  leaves a partly-stored document behind.

  With the default `:abort`, one rejected chunk fails the whole ingest and
  writes nothing:

      {:error, {:embedding_failed, %{chunk_index: 12, reason: reason}}}

  The `chunk_index` is there so you can find the offending input instead of
  guessing which of forty chunks the endpoint refused.

  With `:skip`, the chunks that did embed are stored and the rest are
  reported:

      {:ok, document, %{skipped_chunks: 1, reasons: [...], failed: [%{chunk_index: 12, reason: ...}]}}

  For retrieval, 39 of 40 chunks beats losing the document. The reason is
  also written to `document.error`, so a partial ingest is still explicable
  from the row alone. Skipped chunks leave a gap in `chunk_index` rather
  than renumbering, since a chunk's `"start_byte"`/`"end_byte"` metadata is
  what locates it in the source.

  If *every* chunk fails, `:skip` returns
  `{:error, {:all_chunks_failed, failures}}` and writes nothing: a document
  with no chunks is invisible to search but still counts in listings, which
  is the state this option exists to avoid.

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

  A replacement that fails to embed leaves the predecessor untouched: the
  swap only runs once the new document's chunks are all in hand.
  """
  def ingest(text, opts) when is_binary(text) do
    repo = require_repo!(opts)
    validate_replace_opts!(opts)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})

    {collection_name, collection_description} =
      parse_collection_opt(Keyword.get(opts, :collection, "default"))

    chunk_opts =
      Keyword.take(opts, [
        :chunk_size,
        :chunk_overlap,
        :format,
        :size_unit,
        :chars_per_token,
        :max_chunk_chars
      ])

    chunker_config = Arcana.Config.resolve_chunker(opts)

    start_metadata = %{
      text: text,
      repo: repo,
      collection: collection_name
    }

    :telemetry.span([:arcana, :ingest], start_metadata, fn ->
      case resolve_collection(collection_name, collection_description, repo, opts) do
        {:ok, collection} ->
          doc_attrs = %{
            content: text,
            source_id: source_id,
            metadata: metadata,
            status: :processing,
            collection_id: collection.id
          }

          chunker_config
          |> Chunker.chunk(text, chunk_opts)
          |> embed_and_ingest(doc_attrs, collection, repo, opts)
          |> with_telemetry()

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
    * `:on_chunk_error` - `:abort` (default) or `:skip`. See "When a chunk
      fails to embed" in `ingest/2`.

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
    * `:graph` - Enable GraphRAG extraction (default: from config)
    * `:replace` - When true, atomically replaces any prior document with the
      same `(collection, source_id)` once the new ingest completes. Requires
      `:source_id`. See "Replacing documents" in `ingest/2`.
    * `:on_chunk_error` - `:abort` (default) or `:skip`. See "When a chunk
      fails to embed" in `ingest/2`.

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

  # :telemetry.span/3 wants {result, metadata}; the result itself is whatever
  # embed_and_ingest/5 produced, including the skip report.
  defp with_telemetry({:ok, document} = result) do
    {result, %{document: document, chunk_count: document.chunk_count}}
  end

  defp with_telemetry({:ok, document, report} = result) do
    {result,
     %{
       document: document,
       chunk_count: document.chunk_count,
       skipped_chunks: report.skipped_chunks
     }}
  end

  defp with_telemetry({:error, reason} = result), do: {result, %{error: reason}}

  defp finalize_ingest(document, chunk_records, collection, repo, opts) do
    build_graph_or_fail_document(document, chunk_records, collection, repo, opts)

    if Keyword.get(opts, :replace, false) do
      with {:ok, {document, replaced_chunk_ids}} <-
             finalize_replace(document, chunk_records, repo, opts) do
        cleanup_replaced_graph(replaced_chunk_ids, repo, opts)
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
  defp finalize_replace(document, chunk_records, repo, opts) do
    replace = fn -> do_finalize_replace(document, chunk_records, repo, opts) end

    if Arcana.Config.graph_enabled?(opts) and ecto_graph_store?(opts) do
      GraphStore.with_write_lock(document.collection_id, Keyword.put(opts, :repo, repo), replace)
    else
      replace.()
    end
  end

  defp do_finalize_replace(document, chunk_records, repo, opts) do
    repo.transaction(fn ->
      repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
        "arcana:replace:#{document.collection_id}:#{document.source_id}"
      ])

      if repo.get(Document, document.id) do
        import Ecto.Query, only: [from: 2]

        replaced_chunk_ids =
          repo.all(
            from(c in Chunk,
              join: d in Document,
              on: c.document_id == d.id,
              where:
                d.collection_id == ^document.collection_id and
                  d.source_id == ^document.source_id and d.id != ^document.id,
              select: c.id
            )
          )

        {:ok, document} =
          document
          |> Document.changeset(%{status: :completed, chunk_count: length(chunk_records)})
          |> repo.update()

        # Publish the replacement before retiring predecessor evidence. Graph
        # cleanup can then see identical facts supported by the new document
        # and won't dirty their communities during the handoff. The whole
        # sequence is still one transaction, so a later failure rolls the
        # publication back too.
        maybe_delete_replaced_graph(replaced_chunk_ids, repo, opts)

        repo.delete_all(
          from(d in Document,
            where:
              d.collection_id == ^document.collection_id and
                d.source_id == ^document.source_id and
                d.id != ^document.id
          )
        )

        {document, replaced_chunk_ids}
      else
        repo.rollback(:replaced_by_concurrent_ingest)
      end
    end)
  end

  defp maybe_delete_replaced_graph(replaced_chunk_ids, repo, opts) do
    if Arcana.Config.graph_enabled?(opts) and ecto_graph_store?(opts) do
      case GraphStore.delete_by_chunks(replaced_chunk_ids, Keyword.put(opts, :repo, repo)) do
        :ok -> :ok
        {:error, reason} -> repo.rollback({:graph_cleanup_failed, reason})
      end
    end
  end

  defp cleanup_replaced_graph([], _repo, _opts), do: :ok

  defp cleanup_replaced_graph(chunk_ids, repo, opts) do
    if Arcana.Config.graph_enabled?(opts) and not ecto_graph_store?(opts) do
      case GraphStore.delete_by_chunks(chunk_ids, Keyword.put(opts, :repo, repo)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Arcana: replaced graph cleanup failed: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp ecto_graph_store?(opts) do
    case Keyword.get(opts, :graph_store, GraphStore.backend()) do
      :ecto -> true
      {:ecto, _opts} -> true
      _other -> false
    end
  end

  defp maybe_build_graph(chunk_records, collection, repo, opts) do
    if Arcana.Config.graph_enabled?(opts) do
      Arcana.Graph.build_and_persist(chunk_records, collection, repo, opts)
    end
  end

  # Holding every embedding before writing costs memory proportional to the
  # document: a 384-dim vector is about 6KB as a list, so a 900-chunk
  # document peaks around 7MB. That is inherent to writing atomically -
  # the embeddings all have to exist at once to go in one transaction - and
  # is the trade for never leaving a half-stored document behind.
  #
  # Every chunk is embedded before anything is written. Storing as we went
  # meant one rejected chunk left the document row and the chunks that came
  # before it behind, and nothing filters retrieval by document status, so
  # those chunks stayed searchable under a document marked :failed - a
  # silently half-indexed document.
  #
  # The embedder is remote, so this deliberately does not run inside a
  # transaction: that would hold a pool connection open across N HTTP calls.
  # The writes come after, and they are the only thing wrapped.
  # The one path both ingest/2 and the file/binary entry points take, so
  # neither can drift from the other's failure behaviour.
  defp embed_and_ingest(chunks, doc_attrs, collection, repo, opts) do
    on_chunk_error = validate_chunk_error_opt!(opts)
    {embedded, failed} = embed_chunks(chunks)

    case {on_chunk_error, embedded, failed} do
      {_mode, _embedded, []} ->
        commit(doc_attrs, embedded, collection, repo, opts, [])

      {:abort, _embedded, [first | _]} ->
        # Nothing was written, so there is nothing to clean up.
        {:error, {:embedding_failed, first}}

      {:skip, [], failed} ->
        # Committing here would store exactly the zero-chunk document that
        # makes a failed ingest invisible to search but present in listings.
        {:error, {:all_chunks_failed, failed}}

      {:skip, _embedded, failed} ->
        commit(doc_attrs, embedded, collection, repo, opts, failed)
    end
  end

  defp commit(doc_attrs, embedded, collection, repo, opts, failed) do
    doc_attrs =
      if failed == [],
        do: doc_attrs,
        else: Map.put(doc_attrs, :error, skip_summary(failed))

    with {:ok, {document, chunk_records}} <- store_document(doc_attrs, embedded, repo),
         {:ok, document} <- finalize_ingest(document, chunk_records, collection, repo, opts) do
      if failed == [] do
        {:ok, document}
      else
        {:ok, document,
         %{skipped_chunks: length(failed), reasons: Enum.map(failed, & &1.reason), failed: failed}}
      end
    end
  end

  defp embed_chunks(chunks) do
    emb = Arcana.Config.embedder()

    {embedded, failed} =
      chunks
      |> Enum.map(fn chunk ->
        {chunk, Embedder.embed(emb, chunk.text, intent: :document)}
      end)
      |> Enum.split_with(fn {_chunk, result} -> match?({:ok, _}, result) end)

    {
      Enum.map(embedded, fn {chunk, {:ok, embedding}} -> {chunk, embedding} end),
      Enum.map(failed, fn {chunk, {:error, reason}} ->
        %{chunk_index: chunk.chunk_index, reason: reason}
      end)
    }
  end

  # Inserts the document and its chunks together, so a failure here leaves
  # no row rather than an empty document nothing will ever look at again.
  defp store_document(doc_attrs, embedded, repo) do
    repo.transaction(fn ->
      document =
        %Document{}
        |> Document.changeset(doc_attrs)
        |> repo.insert!()

      chunk_records =
        Enum.map(embedded, fn {chunk, embedding} ->
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
        end)

      {document, chunk_records}
    end)
  end

  defp validate_chunk_error_opt!(opts) do
    case Keyword.get(opts, :on_chunk_error, :abort) do
      mode when mode in [:abort, :skip] ->
        mode

      other ->
        raise ArgumentError,
              "on_chunk_error must be :abort or :skip, got: #{inspect(other)}"
    end
  end

  defp skip_summary(failed) do
    detail =
      failed
      |> Enum.map_join(", ", fn %{chunk_index: i, reason: r} -> "#{i}: #{inspect(r)}" end)

    "#{length(failed)} chunk(s) skipped during ingest (chunk_index: reason) - #{detail}"
  end

  defp ingest_with_file_attrs(text, opts) do
    repo = require_repo!(opts)
    validate_replace_opts!(opts)
    source_id = Keyword.get(opts, :source_id)
    metadata = Keyword.get(opts, :metadata, %{})
    file_path = Keyword.get(opts, :file_path)
    content_type = Keyword.get(opts, :content_type, "text/plain")
    collection_name = Keyword.get(opts, :collection, "default")

    chunk_opts =
      Keyword.take(opts, [
        :chunk_size,
        :chunk_overlap,
        :format,
        :size_unit,
        :chars_per_token,
        :max_chunk_chars
      ])

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
    doc_attrs = %{
      content: text,
      source_id: attrs.source_id,
      metadata: attrs.metadata,
      file_path: attrs.file_path,
      content_type: attrs.content_type,
      status: :processing,
      collection_id: collection.id
    }

    attrs.chunker_config
    |> Chunker.chunk(text, attrs.chunk_opts)
    |> attach_pages(attrs.pages)
    |> embed_and_ingest(doc_attrs, collection, repo, opts)
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
