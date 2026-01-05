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

  @doc """
  Detects communities in the knowledge graph using the Leiden algorithm.

  This runs community detection on entities and relationships, producing
  hierarchical community clusters. Existing communities for the collection(s)
  are cleared before detection.

  ## Options

    * `:collection` - Filter to a specific collection by name (default: all collections)
    * `:resolution` - Community detection resolution (default: 1.0)
    * `:max_level` - Maximum hierarchy levels (default: 3)
    * `:progress` - Function to call with progress updates `fn current, total -> :ok end`

  ## Examples

      # Basic usage - all collections
      Arcana.Maintenance.detect_communities(MyApp.Repo)

      # Single collection
      Arcana.Maintenance.detect_communities(MyApp.Repo, collection: "my-docs")

      # With custom resolution
      Arcana.Maintenance.detect_communities(MyApp.Repo, resolution: 0.5)

  """
  def detect_communities(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)
    resolution = Keyword.get(opts, :resolution, 1.0)
    objective = Keyword.get(opts, :objective, :cpm)
    iterations = Keyword.get(opts, :iterations, 2)
    seed = Keyword.get(opts, :seed, 0)
    min_size = Keyword.get(opts, :min_size, 1)
    max_level = Keyword.get(opts, :max_level, 1)

    collections = fetch_collections(repo, collection_filter)

    if collections == [] do
      {:ok, %{collections: 0, communities: 0}}
    else
      total_collections = length(collections)

      detector_opts = [
        resolution: resolution,
        objective: objective,
        iterations: iterations,
        seed: seed,
        min_size: min_size,
        max_level: max_level
      ]

      detector_module = Arcana.Graph.CommunityDetector.Leiden

      results =
        collections
        |> Enum.with_index(1)
        |> Enum.map(fn {collection, index} ->
          result =
            detect_communities_for_collection(
              collection,
              repo,
              detector_module,
              detector_opts,
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

  defp detect_communities_for_collection(
         collection,
         repo,
         detector_module,
         detector_opts,
         progress_fn
       ) do
    alias Arcana.Graph.{CommunityDetector, Entity, Relationship}

    # Report start
    try do
      progress_fn.(:collection_start, %{collection: collection.name})
    rescue
      _ -> :ok
    end

    # Fetch entities and relationships for this collection
    entities =
      repo.all(
        from(e in Entity,
          where: e.collection_id == ^collection.id,
          select: %{id: e.id, name: e.name, type: e.type}
        )
      )

    relationships =
      repo.all(
        from(r in Relationship,
          join: e in Entity,
          on: r.source_id == e.id,
          where: e.collection_id == ^collection.id,
          select: %{source_id: r.source_id, target_id: r.target_id, strength: r.strength}
        )
      )

    if entities == [] do
      %{communities: 0, entities: 0, relationships: 0}
    else
      # Clear existing communities for this collection
      repo.delete_all(from(c in Arcana.Graph.Community, where: c.collection_id == ^collection.id))

      # Run community detection with configured detector
      detector = {detector_module, detector_opts}

      case CommunityDetector.detect(detector, entities, relationships) do
        {:ok, communities} ->
          # Persist communities
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

  ## Returns

  `{:ok, %{communities: count, summaries: count}}` on success.

  ## Examples

      # Summarize all dirty communities
      Maintenance.summarize_communities(repo)

      # Force regenerate all summaries
      Maintenance.summarize_communities(repo, force: true)

      # Summarize a specific collection
      Maintenance.summarize_communities(repo, collection: "my-docs")

  """
  def summarize_communities(repo, opts \\ []) do
    progress_fn = Keyword.get(opts, :progress, fn _, _ -> :ok end)
    collection_filter = Keyword.get(opts, :collection)
    force = Keyword.get(opts, :force, false)
    concurrency = Keyword.get(opts, :concurrency, 1)

    # Get LLM function from opts or config
    llm =
      Keyword.get_lazy(opts, :llm, fn ->
        case Application.get_env(:arcana, :llm) do
          {provider, llm_opts} -> build_llm_fn(provider, llm_opts)
          nil -> nil
        end
      end)

    unless llm do
      raise "No LLM configured. Set config :arcana, :llm or pass :llm option"
    end

    collections = fetch_collections(repo, collection_filter)

    if collections == [] do
      {:ok, %{communities: 0, summaries: 0}}
    else
      total_collections = length(collections)

      results =
        collections
        |> Enum.with_index(1)
        |> Enum.map(fn {collection, index} ->
          result =
            summarize_communities_for_collection(
              collection,
              repo,
              llm,
              force,
              concurrency,
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
      total_summaries = Enum.sum(Enum.map(results, & &1.summaries))

      {:ok, %{communities: total_communities, summaries: total_summaries}}
    end
  end

  defp summarize_communities_for_collection(
         collection,
         repo,
         llm,
         force,
         concurrency,
         progress_fn
       ) do
    alias Arcana.Graph.{Community, CommunitySummarizer, Entity, Relationship}

    # Report start
    try do
      progress_fn.(:collection_start, %{collection: collection.name})
    rescue
      _ -> :ok
    end

    # Fetch communities for this collection
    communities =
      repo.all(
        from(c in Community,
          where: c.collection_id == ^collection.id,
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

      # Build entity ID to entity map for lookups
      all_entity_ids =
        communities
        |> Enum.flat_map(& &1.entity_ids)
        |> Enum.uniq()

      entities_by_id =
        if all_entity_ids == [] do
          %{}
        else
          repo.all(
            from(e in Entity,
              where: e.id in ^all_entity_ids,
              select: {e.id, %{id: e.id, name: e.name, type: e.type, description: e.description}}
            )
          )
          |> Map.new()
        end

      # Fetch relationships for this collection
      relationships =
        repo.all(
          from(r in Relationship,
            join: src in Entity,
            on: r.source_id == src.id,
            join: tgt in Entity,
            on: r.target_id == tgt.id,
            where: src.collection_id == ^collection.id,
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

      # Process communities (with optional concurrency)
      summaries_generated =
        if concurrency > 1 do
          to_summarize
          |> Task.async_stream(
            fn community ->
              summarize_single_community(community, entities_by_id, relationships, llm, repo)
            end,
            max_concurrency: concurrency,
            timeout: 60_000
          )
          |> Enum.count(fn
            {:ok, :ok} -> true
            _ -> false
          end)
        else
          to_summarize
          |> Enum.count(fn community ->
            summarize_single_community(community, entities_by_id, relationships, llm, repo) == :ok
          end)
        end

      %{communities: length(communities), summaries: summaries_generated}
    end
  end

  defp summarize_single_community(community, entities_by_id, all_relationships, llm, repo) do
    alias Arcana.Graph.{Community, CommunitySummarizer}

    # Get entities for this community
    entity_ids = MapSet.new(community.entity_ids || [])

    entities =
      community.entity_ids
      |> Enum.map(&Map.get(entities_by_id, &1))
      |> Enum.reject(&is_nil/1)

    # Filter relationships to those between community entities
    relationships =
      Enum.filter(all_relationships, fn rel ->
        MapSet.member?(entity_ids, rel.source_id) and MapSet.member?(entity_ids, rel.target_id)
      end)

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

  defp build_llm_fn(provider, llm_opts) when is_binary(provider) do
    fn prompt, context, opts ->
      Arcana.LLM.complete(provider, prompt, context, Keyword.merge(llm_opts, opts))
    end
  end

  defp build_llm_fn({provider, provider_opts}, llm_opts) do
    fn prompt, context, opts ->
      merged = Keyword.merge(llm_opts, opts) |> Keyword.merge(provider_opts)
      Arcana.LLM.complete(provider, prompt, context, merged)
    end
  end
end
