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
  alias Arcana.Graph.{EntityMention, GraphStore}
  alias Ecto.Adapters.SQL

  import Ecto.Query

  @doc """
  Re-embeds all chunks and rechunks documents that have no chunks.

  This is useful when switching embedding models or after a migration
  that cleared chunks.

  ## Options

    * `:batch_size` - Number of items to process at once (default: 50)
    * `:concurrency` - Number of parallel embedding requests (default: 5)
    * `:skip` - Number of chunks to skip (for resuming interrupted runs)
    * `:progress` - Function to call with progress updates `fn current, total -> :ok end`

  ## Examples

      # Basic usage
      Arcana.Maintenance.reembed(MyApp.Repo)

      # With progress callback and concurrency
      Arcana.Maintenance.reembed(MyApp.Repo,
        batch_size: 100,
        concurrency: 10,
        progress: fn current, total ->
          IO.puts("Progress: \#{current}/\#{total}")
        end
      )

      # Resume from chunk 500
      Arcana.Maintenance.reembed(MyApp.Repo, skip: 500)

  """
  def reembed(repo, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 50)
    concurrency = Keyword.get(opts, :concurrency, 5)
    skip = Keyword.get(opts, :skip, 0)
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)

    embedder = Arcana.embedder()
    strict? = Arcana.Config.strict_collections?(opts)

    with {:ok, collection_id} <- Collection.resolve_id(collection_filter, repo, strict?) do
      do_reembed(repo, embedder, collection_id, %{
        batch_size: batch_size,
        concurrency: concurrency,
        skip: skip,
        progress_fn: progress_fn
      })
    end
  end

  defp do_reembed(repo, embedder, collection_id, config) do
    %{batch_size: batch_size, concurrency: concurrency, skip: skip, progress_fn: progress_fn} =
      config

    # First, rechunk documents that have no chunks
    docs_without_chunks = fetch_docs_without_chunks(repo, collection_id)

    rechunked =
      if docs_without_chunks != [] do
        rechunk_documents(docs_without_chunks, embedder, repo, progress_fn)
      else
        0
      end

    # Then re-embed existing chunks
    {total_chunks, reembedded, skipped} =
      reembed_filtered_chunks(
        repo,
        embedder,
        batch_size,
        concurrency,
        skip,
        progress_fn,
        collection_id
      )

    {:ok,
     %{
       rechunked_documents: rechunked,
       reembedded: reembedded,
       total_chunks: total_chunks,
       skipped: skipped
     }}
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

  defp reembed_filtered_chunks(repo, embedder, batch_size, concurrency, skip, progress_fn, nil) do
    total_chunks = repo.aggregate(Chunk, :count)
    chunks_query = from(c in Chunk, order_by: c.id, select: [:id, :text])

    reembedded =
      if total_chunks > 0 do
        reembed_chunks_concurrent(
          repo,
          embedder,
          batch_size,
          concurrency,
          skip,
          progress_fn,
          total_chunks,
          chunks_query
        )
      else
        0
      end

    {total_chunks, reembedded, skip}
  end

  defp reembed_filtered_chunks(
         repo,
         embedder,
         batch_size,
         concurrency,
         skip,
         progress_fn,
         collection_id
       ) do
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
        reembed_chunks_concurrent(
          repo,
          embedder,
          batch_size,
          concurrency,
          skip,
          progress_fn,
          total_chunks,
          chunks_query
        )
      else
        0
      end

    {total_chunks, reembedded, skip}
  end

  defp reembed_chunks_concurrent(
         repo,
         embedder,
         batch_size,
         concurrency,
         skip,
         progress_fn,
         total,
         chunks_query
       ) do
    # Apply skip offset to the query
    query_with_skip = if skip > 0, do: offset(chunks_query, ^skip), else: chunks_query
    chunks_to_process = total - skip

    if chunks_to_process <= 0 do
      0
    else
      ctx = %{
        repo: repo,
        embedder: embedder,
        batch_size: batch_size,
        concurrency: concurrency,
        progress_fn: progress_fn,
        base_query: query_with_skip,
        skip: skip,
        total: total
      }

      reembed_batches_concurrent(ctx, 0)
    end
  end

  defp reembed_batches_concurrent(ctx, batch_offset) do
    chunks =
      ctx.base_query
      |> limit(^ctx.batch_size)
      |> offset(^batch_offset)
      |> ctx.repo.all()

    case chunks do
      [] ->
        0

      _ ->
        embedded_count = embed_batch_concurrent(ctx, chunks, batch_offset)

        if length(chunks) < ctx.batch_size do
          embedded_count
        else
          embedded_count + reembed_batches_concurrent(ctx, batch_offset + ctx.batch_size)
        end
    end
  end

  defp embed_batch_concurrent(ctx, chunks, batch_offset) do
    chunks
    |> Task.async_stream(
      fn chunk ->
        case Embedder.embed(ctx.embedder, chunk.text, intent: :document) do
          {:ok, embedding} -> {:ok, chunk.id, embedding}
          {:error, reason} -> {:error, chunk.id, reason}
        end
      end,
      max_concurrency: ctx.concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.with_index(batch_offset + ctx.skip + 1)
    |> Enum.reduce(0, fn {{:ok, result}, index}, acc ->
      persist_embedding(ctx, result, index)
      acc + 1
    end)
  end

  defp persist_embedding(ctx, {:ok, chunk_id, embedding}, index) do
    ctx.repo.update_all(
      from(c in Chunk, where: c.id == ^chunk_id),
      set: [embedding: embedding, updated_at: DateTime.utc_now()]
    )

    ctx.progress_fn.(index, ctx.total)
  end

  defp persist_embedding(_ctx, {:error, chunk_id, reason}, _index) do
    raise "Failed to embed chunk #{chunk_id}: #{inspect(reason)}"
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

        # Same metadata a fresh ingest would store (byte offsets and any
        # extra keys the chunker reports), so recovered documents aren't
        # the only ones in the corpus missing it. Page numbers are the
        # exception: they come from the parser at ingest time and aren't
        # persisted anywhere, so they can't be rebuilt from the document.
        %Chunk{}
        |> Chunk.changeset(%{
          text: chunk.text,
          embedding: embedding,
          chunk_index: chunk.chunk_index,
          token_count: chunk.token_count,
          metadata: Chunker.metadata_for(chunk),
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
  Embeds entity descriptions for entities that lack embeddings.

  Uses the configured embedder to generate vector embeddings from entity
  descriptions, enabling GraphRAG-style entity similarity search.

  ## Options

    * `:collection` - Only embed entities in this collection
    * `:batch_size` - Entities per batch (default: 100)
    * `:progress` - Progress callback `fn current, total -> :ok end`
    * `:force` - Re-embed all entities, not just those without embeddings (default: false)
  """
  def embed_entities(repo, opts \\ []) do
    import Ecto.Query
    alias Arcana.Graph.Entity

    collection_filter = Keyword.get(opts, :collection)
    batch_size = Keyword.get(opts, :batch_size, 100)
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    force = Keyword.get(opts, :force, false)
    embedder = Arcana.Config.embedder()

    query = from(e in Entity, order_by: e.id, select: [:id, :name, :description, :embedding])
    strict? = Arcana.Config.strict_collections?(opts)

    with {:ok, collection_id} <- Collection.resolve_id(collection_filter, repo, strict?) do
      query =
        if collection_id,
          do: from(e in query, where: e.collection_id == ^collection_id),
          else: query

      query = if force, do: query, else: from(e in query, where: is_nil(e.embedding))

      entities = repo.all(query)
      total = length(entities)

      # The reduce's return value is intentionally discarded: we use the
      # accumulator for per-batch progress reporting, not as a final result.
      _ =
        entities
        |> Enum.chunk_every(batch_size)
        |> Enum.with_index(1)
        |> Enum.reduce(0, fn {batch, _batch_idx}, count ->
          maintenance_batch(batch, count, total, embedder, progress_fn, repo)
        end)

      {:ok, %{total: total}}
    end
  end

  defp maintenance_batch(batch, count, total, embedder, progress_fn, repo) do
    now = NaiveDateTime.utc_now()

    # Embed concurrently so Nx.Serving can batch the requests
    embedded =
      batch
      |> Task.async_stream(
        fn entity -> embed_entity(entity, embedder) end,
        max_concurrency: 64,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, {id, embedding}} -> [{id, embedding}]
        _ -> []
      end)

    bulk_update_embeddings(embedded, now, repo)

    new_count = count + length(batch)
    progress_fn.(new_count, total)
    new_count
  end

  defp embed_entity(entity, embedder) do
    text =
      case entity.description do
        nil -> entity.name
        "" -> entity.name
        desc -> "#{entity.name}: #{desc}"
      end

    case Arcana.Embedder.embed(embedder, text, intent: :document) do
      {:ok, embedding} -> {entity.id, embedding}
      _ -> nil
    end
  end

  defp bulk_update_embeddings([], _now, _repo), do: :ok

  defp bulk_update_embeddings(embedded, now, repo) do
    ids =
      Enum.map(embedded, fn {id, _} ->
        {:ok, bin} = Ecto.UUID.dump(id)
        bin
      end)

    vector_strings =
      Enum.map(embedded, fn {_, vec} ->
        "[" <> Enum.map_join(vec, ",", &to_string/1) <> "]"
      end)

    SQL.query!(
      repo,
      """
      UPDATE arcana_graph_entities AS e
      SET embedding = data.embedding::vector,
          updated_at = $3
      FROM (SELECT unnest($1::uuid[]) AS id, unnest($2::text[]) AS embedding) AS data
      WHERE e.id = data.id
      """,
      [ids, vector_strings, now]
    )

    :ok
  end

  @doc """
  Rebuilds the knowledge graph for documents.

  See module docs for full options.
  """
  def rebuild_graph(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)

    strict? = Arcana.Config.strict_collections?(opts)

    # Get collections (optionally filtered)
    with {:ok, collections} <- fetch_collections(repo, collection_filter, strict?) do
      if collections == [] do
        {:ok, %{collections: 0, entities: 0, relationships: 0, skipped: 0}}
      else
        total_collections = length(collections)

        results =
          rebuild_graph_for_collections(collections, repo, opts, progress_fn, total_collections)

        total_entities = Enum.sum(Enum.map(results, & &1.entities))
        total_relationships = Enum.sum(Enum.map(results, & &1.relationships))
        total_skipped = Enum.sum(Enum.map(results, & &1.skipped))

        {:ok,
         %{
           collections: total_collections,
           entities: total_entities,
           relationships: total_relationships,
           skipped: total_skipped
         }}
      end
    end
  end

  defp rebuild_graph_for_collections(collections, repo, opts, progress_fn, total) do
    collections
    |> Enum.with_index(1)
    |> Enum.map(fn {collection, index} ->
      result = rebuild_graph_for_collection(collection, repo, opts, progress_fn)

      # Try calling with detailed info, fall back to simple progress
      try do
        progress_fn.(:collection_complete, %{
          index: index,
          total: total,
          collection: collection.name,
          result: result
        })
      rescue
        FunctionClauseError -> progress_fn.(index, total)
      end

      result
    end)
  end

  defp rebuild_graph_for_collection(collection, repo, opts, progress_fn) do
    resume = Keyword.get(opts, :resume, false)

    # Only clear existing graph data if not resuming
    unless resume do
      :ok = GraphStore.delete_by_collection(collection.id, repo: repo)
    end

    # Get all chunks for this collection
    all_chunk_records =
      repo.all(
        from(c in Chunk,
          join: d in Document,
          on: d.id == c.document_id,
          where: d.collection_id == ^collection.id,
          select: %{id: c.id, text: c.text}
        )
      )

    # Filter out already-processed chunks if resuming
    {chunk_records, skipped_count} =
      if resume do
        processed_chunk_ids = get_processed_chunk_ids(collection.id, repo)
        filtered = Enum.reject(all_chunk_records, &MapSet.member?(processed_chunk_ids, &1.id))
        {filtered, length(all_chunk_records) - length(filtered)}
      else
        {all_chunk_records, 0}
      end

    chunk_count = length(chunk_records)
    total_chunks = length(all_chunk_records)

    # Report chunk count via callback if it accepts :chunk_start
    try do
      skip_info = if skipped_count > 0, do: " (#{skipped_count} already processed)", else: ""

      progress_fn.(:chunk_start, %{
        collection: collection.name,
        chunk_count: chunk_count,
        skip_info: skip_info
      })
    rescue
      _ -> :ok
    end

    if chunk_records == [] do
      %{entities: 0, relationships: 0, chunks: 0, skipped: skipped_count}
    else
      # Build chunk progress callback that reports to the main progress_fn
      chunk_progress_fn = fn current, _total ->
        try do
          progress_fn.(:chunk_progress, %{
            collection: collection.name,
            current: current + skipped_count,
            total: total_chunks
          })
        rescue
          _ -> :ok
        end
      end

      graph_opts = Keyword.put(opts, :progress, chunk_progress_fn)

      case Arcana.Graph.build_and_persist(chunk_records, collection, repo, graph_opts) do
        {:ok, %{entity_count: entities, relationship_count: relationships}} ->
          %{
            entities: entities,
            relationships: relationships,
            chunks: chunk_count,
            skipped: skipped_count
          }

        {:error, _reason} ->
          %{entities: 0, relationships: 0, chunks: chunk_count, skipped: skipped_count}
      end
    end
  end

  defp get_processed_chunk_ids(collection_id, repo) do
    # Find all chunk IDs that have entity mentions (meaning they've been processed)
    repo.all(
      from(em in EntityMention,
        join: e in Arcana.Graph.Entity,
        on: e.id == em.entity_id,
        where: e.collection_id == ^collection_id,
        select: em.chunk_id,
        distinct: true
      )
    )
    |> MapSet.new()
  end

  defp fetch_collections(repo, nil, _strict?) do
    {:ok, repo.all(from(c in Collection, select: c))}
  end

  defp fetch_collections(repo, collection_name, strict?) when is_binary(collection_name) do
    case repo.all(from(c in Collection, where: c.name == ^collection_name, select: c)) do
      [] when strict? -> {:error, {:unknown_collection, collection_name}}
      collections -> {:ok, collections}
    end
  end

  @doc """
  Returns info about the current graph configuration.

  ## Examples

      iex> Arcana.Maintenance.graph_info()
      %{enabled: true, extractor: :llm}

  """
  def graph_info do
    config = Arcana.Graph.config()
    graph_opts = Arcana.Config.get_env(:graph, [])

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

  @doc """
  Detects communities in the knowledge graph using the Leiden algorithm.

  This runs community detection on entities and relationships, producing
  hierarchical community clusters. Existing communities for the collection(s)
  are cleared before detection.

  ## Options

    * `:collection` - Filter to a specific collection by name (default: all collections)
    * `:resolution` - Community detection resolution (default: 1.0)
    * `:objective` - Quality function (default: `:cpm`)
    * `:iterations` - Optimization iterations (default: 2)
    * `:seed` - Random seed; `0` lets the algorithm randomize (default: 0)
    * `:min_size` - Minimum community size to keep (default: 1)
    * `:max_level` - Maximum hierarchy levels (default: 1, from `:community_levels`)
    * `:progress` - Function to call with progress updates `fn current, total -> :ok end`

  ## Configuration

  Every detection knob can also be set globally, and the detector itself
  is pluggable:

      config :arcana, :graph,
        community_detector: :leiden,
        resolution: 1.0,
        objective: :cpm,
        iterations: 2,
        seed: 42,
        min_size: 1,
        community_levels: 3

  Knobs resolve in this order, later wins: library defaults, then
  `config :arcana, :graph`, then options carried by the configured
  `community_detector` tuple, then the per-call options above.

  ## Examples

      # Basic usage - all collections
      Arcana.Maintenance.detect_communities(MyApp.Repo)

      # Single collection
      Arcana.Maintenance.detect_communities(MyApp.Repo, collection: "my-docs")

      # With custom resolution
      Arcana.Maintenance.detect_communities(MyApp.Repo, resolution: 0.5)

      # Reproducible membership
      Arcana.Maintenance.detect_communities(MyApp.Repo, seed: 42)

  """
  def detect_communities(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)

    strict? = Arcana.Config.strict_collections?(opts)

    with {:ok, collections} <- fetch_collections(repo, collection_filter, strict?) do
      if collections == [] do
        {:ok, %{collections: 0, communities: 0}}
      else
        total_collections = length(collections)
        detector = resolve_detector(opts)

        results =
          collections
          |> Enum.with_index(1)
          |> Enum.map(fn {collection, index} ->
            result =
              detect_communities_for_collection(
                collection,
                repo,
                detector,
                progress_fn
              )

            try do
              progress_fn.(:collection_complete, %{
                index: index,
                total: total_collections,
                collection: collection.name,
                result: result
              })
            rescue
              FunctionClauseError -> progress_fn.(index, total_collections)
            end

            result
          end)

        total_communities = Enum.sum(Enum.map(results, & &1.communities))

        {:ok, %{collections: total_collections, communities: total_communities}}
      end
    end
  end

  @detection_keys [:resolution, :objective, :iterations, :seed, :min_size, :max_level]
  @detection_defaults [
    resolution: 1.0,
    objective: :cpm,
    iterations: 2,
    seed: 0,
    min_size: 1,
    max_level: 1
  ]

  @doc false
  # Resolved detection knobs, for callers that want to report what a
  # detection run will actually use (the detect_communities mix task).
  def detection_opts(opts \\ []) do
    case resolve_detector(opts) do
      {_module, detector_opts} -> detector_opts
      _detector -> resolve_detection_opts(opts, [])
    end
  end

  # Builds the detector from `config :arcana, :graph` plus per-call opts.
  # Precedence, later wins: library defaults, graph config knobs, opts on
  # the configured detector tuple, per-call opts.
  defp resolve_detector(opts) do
    case configured_detector() do
      nil -> nil
      fun when is_function(fun, 3) -> fun
      {module, mod_opts} -> {module, resolve_detection_opts(opts, mod_opts)}
    end
  end

  @doc """
  The community detector this install would use.

  Returns `{module, opts}`, a 3-arity function, or `nil`. Public so callers
  can check the dependency the configured detector actually needs, rather
  than assuming the built-in one.
  """
  def configured_detector do
    case fetch_graph_config(:community_detector) do
      {:ok, value} -> Arcana.Config.parse_community_detector_config(value)
      :error -> {Arcana.Graph.CommunityDetector.Leiden, []}
    end
  end

  defp fetch_graph_config(key) do
    case Arcana.Config.get_env(:graph, []) do
      graph_opts when is_list(graph_opts) -> Keyword.fetch(graph_opts, key)
      %{} = graph_opts -> Map.fetch(graph_opts, key)
      _other -> :error
    end
  end

  defp resolve_detection_opts(opts, mod_opts) do
    @detection_defaults
    |> Keyword.merge(graph_detection_opts())
    |> Keyword.merge(mod_opts)
    |> Keyword.merge(Keyword.take(opts, @detection_keys))
  end

  defp graph_detection_opts do
    graph_config = Arcana.Graph.config()

    [
      resolution: graph_config[:resolution],
      objective: graph_config[:objective],
      iterations: graph_config[:iterations],
      seed: graph_config[:seed],
      min_size: graph_config[:min_size],
      max_level: graph_config[:max_level] || graph_config[:community_levels]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp detect_communities_for_collection(
         collection,
         repo,
         detector,
         progress_fn
       ) do
    alias Arcana.Graph.{CommunityDetector, Entity, Relationship}

    # Report start
    try do
      progress_fn.(:collection_start, %{collection: collection.name})
    rescue
      _ -> :ok
    end

    # Fetch entities and relationships for this collection. The order is
    # pinned: detectors index nodes by position, so a stable seed only
    # yields stable membership when the input order is stable too.
    entities =
      repo.all(
        from(e in Entity,
          where: e.collection_id == ^collection.id,
          order_by: e.id,
          select: %{id: e.id, name: e.name, type: e.type}
        )
      )

    relationships =
      repo.all(
        from(r in Relationship,
          join: e in Entity,
          on: r.source_id == e.id,
          where: e.collection_id == ^collection.id,
          order_by: r.id,
          select: %{source_id: r.source_id, target_id: r.target_id, strength: r.strength}
        )
      )

    if entities == [] do
      %{communities: 0, entities: 0, relationships: 0}
    else
      # Clear existing communities for this collection, keeping what we
      # know about each membership so unchanged ones don't get re-summarized
      previous = snapshot_communities(collection.id, repo)
      repo.delete_all(from(c in Arcana.Graph.Community, where: c.collection_id == ^collection.id))

      case CommunityDetector.detect(detector, entities, relationships) do
        {:ok, communities} ->
          # Persist communities
          communities = Enum.map(communities, &carry_over_summary(&1, previous))
          :ok = GraphStore.persist_communities(collection.id, communities, repo: repo)

          %{
            communities: length(communities),
            entities: length(entities),
            relationships: length(relationships)
          }

        {:error, _reason} ->
          %{communities: 0, entities: length(entities), relationships: length(relationships)}
      end
    end
  end

  # Detection is delete-all + reinsert, so without this every rebuild
  # would recreate each community with a nil summary and dirty: true and
  # the next summarize pass would pay one LLM call per row, even for
  # memberships that didn't change. Keyed on the sorted entity-id set
  # because the community rows themselves are recreated with new ids.
  defp snapshot_communities(collection_id, repo) do
    repo.all(
      from(c in Arcana.Graph.Community,
        where: c.collection_id == ^collection_id,
        select: %{
          entity_ids: c.entity_ids,
          summary: c.summary,
          dirty: c.dirty,
          change_count: c.change_count
        }
      )
    )
    |> Map.new(fn community ->
      {Enum.sort(community.entity_ids || []), Map.delete(community, :entity_ids)}
    end)
  end

  # Carries the previous summary and change tracking over verbatim: a
  # clean community stays clean, one that was already awaiting a refresh
  # stays dirty, and genuinely new memberships keep the schema defaults
  # (nil summary, dirty) so the summarizer picks them up.
  defp carry_over_summary(community, previous) do
    key = community |> Map.get(:entity_ids) |> List.wrap() |> Enum.sort()

    case Map.fetch(previous, key) do
      {:ok, tracking} -> Map.merge(community, tracking)
      :error -> community
    end
  end

  @doc """
  Generates summaries for communities that need them.

  This function iterates through communities and generates LLM summaries
  for those that are dirty, have no summary, or have accumulated changes.

  ## Options

    - `:collection` - Only summarize communities in this collection (default: all)
    - `:progress` - Progress callback function
    - `:force` - Regenerate all summaries even if not dirty (default: false)
    - `:concurrency` - Number of parallel summarization tasks (default: 1)
    - `:llm` - LLM function for summarization (uses config if not provided)
    - `:levels` - Hierarchy levels to summarize: an integer, a list, a range
      or `:all`. Defaults to `config :arcana, :graph, community_summary_level`,
      the levels `Arcana.ask/2` actually reads, so detection can generate a
      deeper hierarchy without paying an LLM call per unread level.

  ## Returns

  `{:ok, %{communities: count, summaries: count}}` on success.

  ## Examples

      # Summarize all dirty communities
      Maintenance.summarize_communities(repo)

      # Force regenerate all summaries
      Maintenance.summarize_communities(repo, force: true)

      # Summarize a specific collection
      Maintenance.summarize_communities(repo, collection: "my-docs")

      # Summarize every hierarchy level, not just the readable ones
      Maintenance.summarize_communities(repo, levels: :all)

  """
  def summarize_communities(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)
    force = Keyword.get(opts, :force, false)
    concurrency = Keyword.get(opts, :concurrency, 1)

    strict? = Arcana.Config.strict_collections?(opts)

    # Validate the collection filter before requiring an LLM, so strict
    # callers get {:error, {:unknown_collection, name}} consistently.
    with {:ok, collections} <- fetch_collections(repo, collection_filter, strict?) do
      summarize_fetched_collections(collections, repo, %{
        opts: opts,
        force: force,
        concurrency: concurrency,
        levels: summary_levels(opts),
        progress_fn: progress_fn
      })
    end
  end

  defp summarize_fetched_collections([], _repo, _config) do
    {:ok, %{communities: 0, summaries: 0}}
  end

  defp summarize_fetched_collections(collections, repo, config) do
    %{opts: opts, progress_fn: progress_fn} = config
    ctx = Map.put(config, :llm, resolve_summarizer_llm!(opts))
    total_collections = length(collections)

    results =
      collections
      |> Enum.with_index(1)
      |> Enum.map(fn {collection, index} ->
        result = summarize_communities_for_collection(collection, repo, ctx)

        try do
          progress_fn.(:collection_complete, %{
            index: index,
            total: total_collections,
            collection: collection.name,
            result: result
          })
        rescue
          FunctionClauseError -> progress_fn.(index, total_collections)
        end

        result
      end)

    total_communities = Enum.sum(Enum.map(results, & &1.communities))
    total_summaries = Enum.sum(Enum.map(results, & &1.summaries))

    {:ok, %{communities: total_communities, summaries: total_summaries}}
  end

  # Normalize the LLM to a 3-arity function through the Arcana.LLM
  # protocol, so every supported config shape (model string, {model, opts},
  # {module, function}, anonymous function) works here.
  defp resolve_summarizer_llm!(opts) do
    case Keyword.get_lazy(opts, :llm, fn -> Arcana.Config.get_env(:llm) end) do
      nil ->
        raise "No LLM configured. Set config :arcana, :llm or pass :llm option"

      llm ->
        fn prompt, context, call_opts ->
          Arcana.LLM.complete(llm, prompt, context, call_opts)
        end
    end
  end

  defp summarize_communities_for_collection(collection, repo, ctx) do
    alias Arcana.Graph.{Community, CommunitySummarizer, Entity, Relationship}

    %{llm: llm, force: force, concurrency: concurrency, progress_fn: progress_fn} = ctx

    # Report start
    try do
      progress_fn.(:collection_start, %{collection: collection.name})
    rescue
      _ -> :ok
    end

    # Fetch the communities a query path can actually read: summarizing a
    # level nothing reads costs one LLM call per row for nothing.
    communities =
      repo.all(
        from(c in Community,
          where: c.collection_id == ^collection.id,
          where: ^level_filter(ctx.levels),
          select: c
        )
      )

    if communities == [] do
      %{communities: 0, summaries: 0}
    else
      # Filter to communities that need summarization
      to_summarize =
        if force do
          communities
        else
          Enum.filter(communities, &CommunitySummarizer.needs_regeneration?/1)
        end

      # Process communities (with optional concurrency), fetching data per-community
      summaries_generated =
        if concurrency > 1 do
          to_summarize
          |> Task.async_stream(
            fn community ->
              summarize_single_community(community, repo, llm)
            end,
            max_concurrency: concurrency,
            timeout: :infinity
          )
          |> Enum.count(fn
            {:ok, :ok} -> true
            _ -> false
          end)
        else
          to_summarize
          |> Enum.count(fn community ->
            summarize_single_community(community, repo, llm) == :ok
          end)
        end

      %{communities: length(communities), summaries: summaries_generated}
    end
  end

  # Levels to summarize: per-call `:levels` wins, otherwise the levels
  # `ask/2` reads (`community_summary_level`), so the two can't drift.
  defp summary_levels(opts) do
    case Keyword.fetch(opts, :levels) do
      {:ok, levels} -> Arcana.Graph.normalize_levels(levels)
      :error -> Arcana.Graph.summary_levels()
    end
  end

  defp level_filter(:all), do: dynamic([c], not is_nil(c.level))
  defp level_filter(levels), do: dynamic([c], c.level in ^levels)

  defp summarize_single_community(community, repo, llm) do
    alias Arcana.Graph.{Community, CommunitySummarizer, Entity, Relationship}

    entity_ids = community.entity_ids || []

    entities =
      repo.all(
        from(e in Entity,
          where: e.id in ^entity_ids,
          select: %{id: e.id, name: e.name, type: e.type, description: e.description}
        )
      )

    relationships =
      repo.all(
        from(r in Relationship,
          join: src in Entity,
          on: r.source_id == src.id,
          join: tgt in Entity,
          on: r.target_id == tgt.id,
          where: r.source_id in ^entity_ids and r.target_id in ^entity_ids,
          select: %{
            source_id: r.source_id,
            target_id: r.target_id,
            source: src.name,
            target: tgt.name,
            type: r.type,
            description: r.description
          }
        )
      )

    # Generate summary
    case CommunitySummarizer.summarize(entities, relationships, llm: llm) do
      {:ok, summary} ->
        # Update community with summary
        community
        |> Community.changeset(%{
          summary: summary,
          dirty: false,
          change_count: 0
        })
        |> repo.update()

        :ok

      {:error, _reason} ->
        :error
    end
  end
end
