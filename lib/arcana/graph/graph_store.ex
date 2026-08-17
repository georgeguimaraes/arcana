defmodule Arcana.Graph.GraphStore do
  @moduledoc """
  Behaviour and dispatch module for graph storage backends.

  Arcana supports swappable graph storage:

  - `:ecto` (default) - PostgreSQL via Ecto
  - `:memory` - In-memory storage for testing
  - Custom module implementing this behaviour

  ## Configuration

      # config/config.exs

      # Use Ecto/PostgreSQL (default)
      config :arcana, :graph_store, :ecto

      # With options
      config :arcana, :graph_store, {:ecto, repo: MyApp.Repo}

      # Custom module
      config :arcana, :graph_store, MyApp.CustomGraphStore

  """

  # === Storage Callbacks ===

  @doc """
  Persists entities to the graph store.

  Returns a map of entity names to their assigned IDs.
  """
  @callback persist_entities(binary(), [map()], opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Persists relationships between entities.
  """
  @callback persist_relationships([map()], map(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Persists entity mentions (links between entities and chunks).
  """
  @callback persist_mentions([map()], map(), opts :: keyword()) ::
              :ok | {:error, term()}

  # === Query Callbacks ===

  @doc """
  Searches for chunks related to the given entity names.

  Returns scored chunk results.
  """
  @callback search([String.t()], [binary()] | nil, opts :: keyword()) ::
              [map()]

  @doc """
  Searches for entities by embedding similarity.

  Returns entities whose description embeddings are most similar to the
  query embedding, sorted by similarity descending.
  """
  @callback search_by_embedding([float()], [binary()] | nil, opts :: keyword()) ::
              [map()]

  @doc """
  Finds all entities in a collection.
  """
  @callback find_entities(binary(), opts :: keyword()) :: [map()]

  # === Traversal Callbacks ===

  @doc """
  Finds entities related to the given entity within the specified depth.

  Enables graph-native traversal operations.
  """
  @callback find_related_entities(binary(), depth :: pos_integer(), opts :: keyword()) ::
              [map()]

  # === Community Callbacks ===

  @doc """
  Persists community data for a collection.
  """
  @callback persist_communities(binary(), [map()], opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Retrieves community summaries for a collection.
  """
  @callback get_community_summaries(binary(), opts :: keyword()) :: [map()]

  # === Deletion Callbacks ===

  @doc """
  Deletes all graph data for the given chunk IDs.

  Removes mentions referencing these chunks, then sweeps entities the
  deletion orphaned. The sweep is scoped to the collections those chunks
  belonged to, so deleting in one tenant leaves every other tenant's graph
  alone.

  Prefer `Arcana.delete/2`, which removes the document and its chunks and
  sweeps in one step. Reach for this only when you are deleting chunks
  yourself.

  ## The call is not atomic

  In the Ecto backend the mention delete and the per-collection sweeps are
  separate transactions: the collections to sweep aren't known until the
  delete says which entities it touched, and a collection can't be locked
  before it has been identified. A crash or a dropped connection between
  them commits the delete and skips the rest, leaving entities with no
  mentions behind.

  Nothing is lost and nothing is wrongly retained: an entity with no
  mentions is exactly what a sweep collects, and every sweep is idempotent,
  so the next one over that collection finishes the job. Those run from
  `Arcana.delete/2` (through `maybe_sweep_orphans/3`), after a
  `replace: true` ingest, and from the dashboard's maintenance page, which
  also reports the outstanding orphan count.

  The memory backend has no such window, since the whole operation is one
  `GenServer` call.
  """
  @callback delete_by_chunks(chunk_ids :: [binary()], opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Deletes all graph data for a collection.

  Removes all entities, relationships, mentions, and communities
  associated with the collection.
  """
  @callback delete_by_collection(binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Sweeps orphaned graph data in a collection.

  Deletes entities in the collection that have no remaining mentions
  (their relationships cascade away), and marks communities whose
  `entity_ids` overlap the deleted entities as dirty so the next
  summarize pass regenerates them.

  Intended to run after document deletion or replacement, scoped to the
  affected collection.

  Optional. A store that doesn't implement it simply doesn't sweep:
  `Arcana.delete/2` and the `replace: true` ingest still succeed, and the
  collection may keep entities with zero mentions — which is exactly how
  both paths behaved before this callback existed.

  ## Serialization

  A sweep must not interleave with a graph build for the same collection:
  a build inserts an entity before its mentions, so a sweep landing in
  that window would delete an entity that is about to be referenced.

  The `:ecto` backend serializes both sides through `with_write_lock/3`
  (a transaction-scoped Postgres advisory lock keyed on the collection).
  The `:memory` backend serializes individual calls through its GenServer
  but leaves the window between the entity and mention calls open, which
  is fine for a test backend. Custom backends get the full guarantee only
  if they implement `with_write_lock/3`.
  """
  @callback sweep_orphans(binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  # === Locking Callbacks ===

  @doc """
  Runs `fun` while holding the collection's graph write lock.

  Optional. Backends that can serialize concurrent graph writes implement
  this so `sweep_orphans/2` and the entity/mention persist path cannot
  interleave. Backends that don't implement it simply run `fun`.

  The lock is meant to cover DB writes only, never extraction, so callers
  keep the wrapped work short.

  ## Guarantees

  The contract is mutual exclusion per collection, nothing more.
  Atomicity is best-effort and store-dependent: callers must not assume
  that a failure inside `fun` rolls back the writes it already made.

  The `:ecto` backend does give both, because it takes the advisory lock
  inside a transaction. The `:memory` backend implements neither (it
  falls through to running `fun`), so a mid-`fun` failure leaves partial
  graph data behind, which is fine for a test backend.

  A custom store that wants the full guarantee has to do what the `:ecto`
  backend does: hold a per-collection exclusive lock *and* run `fun`
  inside a transaction that rolls back on failure, releasing the lock
  when the transaction ends. Doing only one of the two is worse than
  doing neither, since it reads as if both were covered.
  """
  @callback with_write_lock(binary(), opts :: keyword(), (-> result)) :: result
            when result: term()

  @optional_callbacks with_write_lock: 3, sweep_orphans: 2

  # === Detail Query Callbacks ===

  @doc """
  Retrieves a single entity by ID.
  """
  @callback get_entity(binary(), opts :: keyword()) ::
              {:ok, map()} | {:error, :not_found}

  @doc """
  Retrieves all relationships for an entity.

  Returns relationships where the entity is either source or target.
  """
  @callback get_relationships(binary(), opts :: keyword()) :: [map()]

  @doc """
  Retrieves a single relationship by ID.
  """
  @callback get_relationship(relationship_id :: binary(), opts :: keyword()) ::
              {:ok, map()} | {:error, :not_found}

  @doc """
  Retrieves mentions for an entity with chunk context.

  Returns mentions with associated chunk text for display.
  """
  @callback get_mentions(binary(), opts :: keyword()) :: [map()]

  @doc """
  Retrieves a single community by ID.
  """
  @callback get_community(community_id :: binary(), opts :: keyword()) ::
              {:ok, map()} | {:error, :not_found}

  # === List Callbacks (for UI) ===

  @doc """
  Lists entities with optional filtering and pagination.

  ## Options

    * `:collection_id` - Filter by collection (nil for all)
    * `:type` - Filter by entity type
    * `:search` - Search in entity name
    * `:limit` - Maximum results (default: 50)
    * `:offset` - Pagination offset (default: 0)

  Returns entities with aggregated counts (mention_count, relationship_count).
  """
  @callback list_entities(opts :: keyword()) :: [map()]

  @doc """
  Lists relationships with optional filtering and pagination.

  ## Options

    * `:collection_id` - Filter by collection (nil for all)
    * `:type` - Filter by relationship type
    * `:search` - Search in entity names or type
    * `:strength` - Filter by strength (:strong, :medium, :weak)
    * `:limit` - Maximum results (default: 50)
    * `:offset` - Pagination offset (default: 0)

  Returns relationships with source/target entity names.
  """
  @callback list_relationships(opts :: keyword()) :: [map()]

  @doc """
  Lists communities with optional filtering and pagination.

  ## Options

    * `:collection_id` - Filter by collection (nil for all)
    * `:level` - Filter by hierarchy level
    * `:search` - Search in summary
    * `:limit` - Maximum results (default: 50)
    * `:offset` - Pagination offset (default: 0)

  Returns communities with entity counts.
  """
  @callback list_communities(opts :: keyword()) :: [map()]

  # === Dispatch Functions ===

  @doc """
  Returns the configured graph store backend.
  """
  def backend do
    Arcana.Config.get_env(:graph_store, :ecto)
  end

  @doc """
  Persists entities using the configured backend.
  """
  def persist_entities(collection_id, entities, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :persist_entities],
      %{collection_id: collection_id, entity_count: length(entities)},
      fn ->
        result =
          dispatch(:persist_entities, backend, [collection_id, entities], backend_opts, opts)

        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Persists relationships using the configured backend.
  """
  def persist_relationships(relationships, entity_id_map, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :persist_relationships],
      %{relationship_count: length(relationships)},
      fn ->
        result =
          dispatch(
            :persist_relationships,
            backend,
            [relationships, entity_id_map],
            backend_opts,
            opts
          )

        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Persists entity mentions using the configured backend.
  """
  def persist_mentions(mentions, entity_id_map, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :persist_mentions],
      %{mention_count: length(mentions)},
      fn ->
        result =
          dispatch(:persist_mentions, backend, [mentions, entity_id_map], backend_opts, opts)

        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Searches for chunks using the configured backend.
  """
  def search(entity_names, collection_ids, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :search],
      %{entity_count: length(entity_names)},
      fn ->
        results = dispatch(:search, backend, [entity_names, collection_ids], backend_opts, opts)
        {results, %{backend: backend, result_count: length(results)}}
      end
    )
  end

  @doc """
  Searches for entities by embedding similarity using the configured backend.
  """
  def search_by_embedding(query_embedding, collection_ids, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :embedding_search],
      %{},
      fn ->
        results =
          dispatch(
            :search_by_embedding,
            backend,
            [query_embedding, collection_ids],
            backend_opts,
            opts
          )

        {results, %{backend: backend, result_count: length(results)}}
      end
    )
  end

  @doc """
  Finds entities using the configured backend.
  """
  def find_entities(collection_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:find_entities, backend, [collection_id], backend_opts, opts)
  end

  @doc """
  Finds related entities using the configured backend.
  """
  def find_related_entities(entity_id, depth, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:find_related_entities, backend, [entity_id, depth], backend_opts, opts)
  end

  @doc """
  Persists communities using the configured backend.
  """
  def persist_communities(collection_id, communities, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:persist_communities, backend, [collection_id, communities], backend_opts, opts)
  end

  @doc """
  Gets community summaries using the configured backend.
  """
  def get_community_summaries(collection_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_community_summaries, backend, [collection_id], backend_opts, opts)
  end

  @doc """
  Deletes all graph data for the given chunk IDs.

  The orphan sweep is scoped to the collections the chunks belonged to. It
  used to run across every collection in the database, which made this
  impossible to call safely in a multi-tenant app.

  `Arcana.delete/2` is usually what you want: it removes the document, its
  chunks and their graph data together.
  """
  def delete_by_chunks(chunk_ids, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :delete_by_chunks],
      %{chunk_count: length(chunk_ids)},
      fn ->
        result = dispatch(:delete_by_chunks, backend, [chunk_ids], backend_opts, opts)
        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Deletes all graph data for a collection using the configured backend.
  """
  def delete_by_collection(collection_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :delete_by_collection],
      %{collection_id: collection_id},
      fn ->
        result = dispatch(:delete_by_collection, backend, [collection_id], backend_opts, opts)
        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Sweeps orphaned graph data in a collection using the configured backend.
  """
  def sweep_orphans(collection_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span(
      [:arcana, :graph_store, :sweep_orphans],
      %{collection_id: collection_id},
      fn ->
        result = dispatch(:sweep_orphans, backend, [collection_id], backend_opts, opts)
        {result, %{backend: backend}}
      end
    )
  end

  @doc """
  Sweeps orphaned graph data when the graph is enabled for this call.

  Shared by `Arcana.delete/2` and the `replace: true` ingest path: both
  drop documents whose chunks cascade away, which can strand zero-mention
  entities. Returns `:ok` when there is nothing to sweep (no collection,
  or the graph is disabled), otherwise the backend's result.
  """
  def maybe_sweep_orphans(collection_id, repo, opts) do
    if collection_id && Arcana.Config.graph_enabled?(opts) do
      sweep_orphans(collection_id, Keyword.put(opts, :repo, repo))
    else
      :ok
    end
  end

  @doc """
  Runs `fun` holding the collection's graph write lock on the configured backend.

  Backends that don't implement `c:with_write_lock/3` just run `fun`, with
  no locking and no rollback. See `c:with_write_lock/3` for what each
  backend actually guarantees.
  """
  def with_write_lock(collection_id, opts, fun) when is_function(fun, 0) do
    {backend, backend_opts, opts} = extract_backend(opts)
    lock(backend, collection_id, Keyword.merge(backend_opts, opts), fun)
  end

  defp lock(:ecto, collection_id, opts, fun),
    do: __MODULE__.Ecto.with_write_lock(collection_id, opts, fun)

  defp lock(:memory, _collection_id, _opts, fun), do: fun.()

  defp lock(module, collection_id, opts, fun) do
    if Code.ensure_loaded?(module) and function_exported?(module, :with_write_lock, 3) do
      module.with_write_lock(collection_id, opts, fun)
    else
      fun.()
    end
  end

  @doc """
  Gets a single entity by ID using the configured backend.
  """
  def get_entity(entity_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_entity, backend, [entity_id], backend_opts, opts)
  end

  @doc """
  Gets relationships for an entity using the configured backend.
  """
  def get_relationships(entity_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_relationships, backend, [entity_id], backend_opts, opts)
  end

  @doc """
  Gets a single relationship by ID using the configured backend.
  """
  def get_relationship(relationship_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_relationship, backend, [relationship_id], backend_opts, opts)
  end

  @doc """
  Gets mentions for an entity using the configured backend.
  """
  def get_mentions(entity_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_mentions, backend, [entity_id], backend_opts, opts)
  end

  @doc """
  Gets a single community by ID using the configured backend.
  """
  def get_community(community_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:get_community, backend, [community_id], backend_opts, opts)
  end

  @doc """
  Lists entities using the configured backend.
  """
  def list_entities(opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:list_entities, backend, [], backend_opts, opts)
  end

  @doc """
  Lists relationships using the configured backend.
  """
  def list_relationships(opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:list_relationships, backend, [], backend_opts, opts)
  end

  @doc """
  Lists communities using the configured backend.
  """
  def list_communities(opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:list_communities, backend, [], backend_opts, opts)
  end

  # === Private Helpers ===

  defp extract_backend(opts) do
    {graph_store, opts} = Keyword.pop(opts, :graph_store, backend())

    case graph_store do
      {backend, backend_opts} when is_atom(backend) and is_list(backend_opts) ->
        {backend, backend_opts, opts}

      backend when is_atom(backend) ->
        {backend, [], opts}
    end
  end

  # Dispatch to Ecto backend
  defp dispatch(:persist_entities, :ecto, [collection_id, entities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.persist_entities(collection_id, entities, opts)
  end

  defp dispatch(:persist_relationships, :ecto, [relationships, entity_id_map], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.persist_relationships(relationships, entity_id_map, opts)
  end

  defp dispatch(:persist_mentions, :ecto, [mentions, entity_id_map], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.persist_mentions(mentions, entity_id_map, opts)
  end

  defp dispatch(:search, :ecto, [entity_names, collection_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.search(entity_names, collection_ids, opts)
  end

  defp dispatch(
         :search_by_embedding,
         :ecto,
         [query_embedding, collection_ids],
         backend_opts,
         opts
       ) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.search_by_embedding(query_embedding, collection_ids, opts)
  end

  defp dispatch(:find_entities, :ecto, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.find_entities(collection_id, opts)
  end

  defp dispatch(:find_related_entities, :ecto, [entity_id, depth], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.find_related_entities(entity_id, depth, opts)
  end

  defp dispatch(:persist_communities, :ecto, [collection_id, communities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.persist_communities(collection_id, communities, opts)
  end

  defp dispatch(:get_community_summaries, :ecto, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_community_summaries(collection_id, opts)
  end

  defp dispatch(:delete_by_chunks, :ecto, [chunk_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.delete_by_chunks(chunk_ids, opts)
  end

  defp dispatch(:delete_by_collection, :ecto, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.delete_by_collection(collection_id, opts)
  end

  defp dispatch(:sweep_orphans, :ecto, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.sweep_orphans(collection_id, opts)
  end

  defp dispatch(:get_entity, :ecto, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_entity(entity_id, opts)
  end

  defp dispatch(:get_relationships, :ecto, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_relationships(entity_id, opts)
  end

  defp dispatch(:get_relationship, :ecto, [relationship_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_relationship(relationship_id, opts)
  end

  defp dispatch(:get_mentions, :ecto, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_mentions(entity_id, opts)
  end

  defp dispatch(:get_community, :ecto, [community_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.get_community(community_id, opts)
  end

  defp dispatch(:list_entities, :ecto, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.list_entities(opts)
  end

  defp dispatch(:list_relationships, :ecto, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.list_relationships(opts)
  end

  defp dispatch(:list_communities, :ecto, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Ecto.list_communities(opts)
  end

  # Dispatch to Memory backend
  defp dispatch(:persist_entities, :memory, [collection_id, entities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.persist_entities(collection_id, entities, opts)
  end

  defp dispatch(
         :persist_relationships,
         :memory,
         [relationships, entity_id_map],
         backend_opts,
         opts
       ) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.persist_relationships(relationships, entity_id_map, opts)
  end

  defp dispatch(:persist_mentions, :memory, [mentions, entity_id_map], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.persist_mentions(mentions, entity_id_map, opts)
  end

  defp dispatch(:search, :memory, [entity_names, collection_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.search(entity_names, collection_ids, opts)
  end

  defp dispatch(
         :search_by_embedding,
         :memory,
         [query_embedding, collection_ids],
         backend_opts,
         opts
       ) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.search_by_embedding(query_embedding, collection_ids, opts)
  end

  defp dispatch(:find_entities, :memory, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.find_entities(collection_id, opts)
  end

  defp dispatch(:find_related_entities, :memory, [entity_id, depth], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.find_related_entities(entity_id, depth, opts)
  end

  defp dispatch(:persist_communities, :memory, [collection_id, communities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.persist_communities(collection_id, communities, opts)
  end

  defp dispatch(:get_community_summaries, :memory, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_community_summaries(collection_id, opts)
  end

  defp dispatch(:delete_by_chunks, :memory, [chunk_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.delete_by_chunks(chunk_ids, opts)
  end

  defp dispatch(:delete_by_collection, :memory, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.delete_by_collection(collection_id, opts)
  end

  defp dispatch(:sweep_orphans, :memory, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.sweep_orphans(collection_id, opts)
  end

  defp dispatch(:get_entity, :memory, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_entity(entity_id, opts)
  end

  defp dispatch(:get_relationships, :memory, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_relationships(entity_id, opts)
  end

  defp dispatch(:get_relationship, :memory, [relationship_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_relationship(relationship_id, opts)
  end

  defp dispatch(:get_mentions, :memory, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_mentions(entity_id, opts)
  end

  defp dispatch(:get_community, :memory, [community_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.get_community(community_id, opts)
  end

  defp dispatch(:list_entities, :memory, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.list_entities(opts)
  end

  defp dispatch(:list_relationships, :memory, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.list_relationships(opts)
  end

  defp dispatch(:list_communities, :memory, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    __MODULE__.Memory.list_communities(opts)
  end

  # Dispatch to custom module
  defp dispatch(:persist_entities, module, [collection_id, entities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.persist_entities(collection_id, entities, opts)
  end

  defp dispatch(
         :persist_relationships,
         module,
         [relationships, entity_id_map],
         backend_opts,
         opts
       ) do
    opts = Keyword.merge(backend_opts, opts)
    module.persist_relationships(relationships, entity_id_map, opts)
  end

  defp dispatch(:persist_mentions, module, [mentions, entity_id_map], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.persist_mentions(mentions, entity_id_map, opts)
  end

  defp dispatch(:search, module, [entity_names, collection_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.search(entity_names, collection_ids, opts)
  end

  defp dispatch(
         :search_by_embedding,
         module,
         [query_embedding, collection_ids],
         backend_opts,
         opts
       ) do
    opts = Keyword.merge(backend_opts, opts)
    module.search_by_embedding(query_embedding, collection_ids, opts)
  end

  defp dispatch(:find_entities, module, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.find_entities(collection_id, opts)
  end

  defp dispatch(:find_related_entities, module, [entity_id, depth], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.find_related_entities(entity_id, depth, opts)
  end

  defp dispatch(:persist_communities, module, [collection_id, communities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.persist_communities(collection_id, communities, opts)
  end

  defp dispatch(:get_community_summaries, module, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_community_summaries(collection_id, opts)
  end

  defp dispatch(:delete_by_chunks, module, [chunk_ids], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.delete_by_chunks(chunk_ids, opts)
  end

  defp dispatch(:delete_by_collection, module, [collection_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.delete_by_collection(collection_id, opts)
  end

  # sweep_orphans/2 is optional, like with_write_lock/3: a store written
  # against the behaviour before the callback existed keeps working, and
  # skipping the sweep is what those callers already did.
  defp dispatch(:sweep_orphans, module, [collection_id], backend_opts, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :sweep_orphans, 2) do
      module.sweep_orphans(collection_id, Keyword.merge(backend_opts, opts))
    else
      :ok
    end
  end

  defp dispatch(:get_entity, module, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_entity(entity_id, opts)
  end

  defp dispatch(:get_relationships, module, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_relationships(entity_id, opts)
  end

  defp dispatch(:get_relationship, module, [relationship_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_relationship(relationship_id, opts)
  end

  defp dispatch(:get_mentions, module, [entity_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_mentions(entity_id, opts)
  end

  defp dispatch(:get_community, module, [community_id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.get_community(community_id, opts)
  end

  defp dispatch(:list_entities, module, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.list_entities(opts)
  end

  defp dispatch(:list_relationships, module, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.list_relationships(opts)
  end

  defp dispatch(:list_communities, module, [], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.list_communities(opts)
  end
end
