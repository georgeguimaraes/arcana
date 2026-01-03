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

  # Dispatch to custom module
  defp dispatch(:persist_entities, module, [collection_id, entities], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.persist_entities(collection_id, entities, opts)
  end

  defp dispatch(:persist_relationships, module, [relationships, entity_id_map], backend_opts, opts) do
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
end
