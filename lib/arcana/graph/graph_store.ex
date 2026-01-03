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

  @type collection_id :: binary()
  @type entity_id :: binary()
  @type entity :: map()
  @type relationship :: map()
  @type mention :: map()
  @type community :: map()
  @type entity_id_map :: %{String.t() => binary()}
  @type search_result :: %{chunk_id: binary(), score: float()}

  # === Storage Callbacks ===

  @doc """
  Persists entities to the graph store.

  Returns a map of entity names to their assigned IDs.
  """
  @callback persist_entities(collection_id(), [entity()], opts :: keyword()) ::
              {:ok, entity_id_map()} | {:error, term()}

  @doc """
  Persists relationships between entities.
  """
  @callback persist_relationships([relationship()], entity_id_map(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Persists entity mentions (links between entities and chunks).
  """
  @callback persist_mentions([mention()], entity_id_map(), opts :: keyword()) ::
              :ok | {:error, term()}

  # === Query Callbacks ===

  @doc """
  Searches for chunks related to the given entity names.

  Returns scored chunk results.
  """
  @callback search([String.t()], [collection_id()] | nil, opts :: keyword()) ::
              [search_result()]

  @doc """
  Finds all entities in a collection.
  """
  @callback find_entities(collection_id(), opts :: keyword()) :: [entity()]

  # === Traversal Callbacks ===

  @doc """
  Finds entities related to the given entity within the specified depth.

  Enables graph-native traversal operations.
  """
  @callback find_related_entities(entity_id(), depth :: pos_integer(), opts :: keyword()) ::
              [entity()]

  # === Community Callbacks ===

  @doc """
  Persists community data for a collection.
  """
  @callback persist_communities(collection_id(), [community()], opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Retrieves community summaries for a collection.
  """
  @callback get_community_summaries(collection_id(), opts :: keyword()) :: [community()]

  # === Deletion Callbacks ===

  @doc """
  Deletes all graph data for the given chunk IDs.

  Removes mentions referencing these chunks, and cleans up orphaned entities
  (entities with no remaining mentions).
  """
  @callback delete_by_chunks(chunk_ids :: [binary()], opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Deletes all graph data for a collection.

  Removes all entities, relationships, mentions, and communities
  associated with the collection.
  """
  @callback delete_by_collection(collection_id(), opts :: keyword()) ::
              :ok | {:error, term()}

  # === Detail Query Callbacks ===

  @doc """
  Retrieves a single entity by ID.
  """
  @callback get_entity(entity_id(), opts :: keyword()) ::
              {:ok, entity()} | {:error, :not_found}

  @doc """
  Retrieves all relationships for an entity.

  Returns relationships where the entity is either source or target.
  """
  @callback get_relationships(entity_id(), opts :: keyword()) :: [relationship()]

  @doc """
  Retrieves a single relationship by ID.
  """
  @callback get_relationship(relationship_id :: binary(), opts :: keyword()) ::
              {:ok, relationship()} | {:error, :not_found}

  @doc """
  Retrieves mentions for an entity with chunk context.

  Returns mentions with associated chunk text for display.
  """
  @callback get_mentions(entity_id(), opts :: keyword()) :: [mention()]

  @doc """
  Retrieves a single community by ID.
  """
  @callback get_community(community_id :: binary(), opts :: keyword()) ::
              {:ok, community()} | {:error, :not_found}

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
  @callback list_entities(opts :: keyword()) :: [entity()]

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
  @callback list_relationships(opts :: keyword()) :: [relationship()]

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
  @callback list_communities(opts :: keyword()) :: [community()]

  # === Dispatch Functions ===

  @doc """
  Returns the configured graph store backend.
  """
  def backend do
    Application.get_env(:arcana, :graph_store, :ecto)
  end

  @doc """
  Persists entities using the configured backend.
  """
  def persist_entities(collection_id, entities, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:persist_entities, backend, [collection_id, entities], backend_opts, opts)
  end

  @doc """
  Persists relationships using the configured backend.
  """
  def persist_relationships(relationships, entity_id_map, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:persist_relationships, backend, [relationships, entity_id_map], backend_opts, opts)
  end

  @doc """
  Persists entity mentions using the configured backend.
  """
  def persist_mentions(mentions, entity_id_map, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:persist_mentions, backend, [mentions, entity_id_map], backend_opts, opts)
  end

  @doc """
  Searches for chunks using the configured backend.
  """
  def search(entity_names, collection_ids, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:search, backend, [entity_names, collection_ids], backend_opts, opts)
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
  Deletes graph data for the given chunk IDs using the configured backend.
  """
  def delete_by_chunks(chunk_ids, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:delete_by_chunks, backend, [chunk_ids], backend_opts, opts)
  end

  @doc """
  Deletes all graph data for a collection using the configured backend.
  """
  def delete_by_collection(collection_id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    dispatch(:delete_by_collection, backend, [collection_id], backend_opts, opts)
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
