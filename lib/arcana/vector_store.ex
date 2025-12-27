defmodule Arcana.VectorStore do
  @moduledoc """
  Behaviour and dispatch module for vector storage backends.

  Arcana supports two vector storage backends:

  - `:pgvector` (default) - PostgreSQL with pgvector extension
  - `:memory` - In-memory storage using HNSWLib

  ## Configuration

      # config/config.exs

      # Use pgvector (default)
      config :arcana, vector_store: :pgvector

      # Use in-memory storage
      config :arcana, vector_store: :memory

  ## In-Memory Backend

  When using `:memory`, you need to start the Memory server in your supervision tree:

      children = [
        MyApp.Repo,
        {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}
      ]

  The Memory backend is useful for:
  - Testing embedding models without database migrations
  - Smaller RAGs where pgvector overhead isn't justified
  - Development and experimentation workflows

  Note: Memory backend data is not persisted - all vectors are lost when the process stops.

  ## Custom Backend

  To implement a custom backend, create a module that implements the `Arcana.VectorStore` behaviour:

      defmodule MyApp.CustomVectorStore do
        @behaviour Arcana.VectorStore

        @impl true
        def store(collection, id, embedding, metadata, opts) do
          # Your implementation
        end

        @impl true
        def search(collection, query_embedding, opts) do
          # Your implementation
        end

        @impl true
        def delete(collection, id, opts) do
          # Your implementation
        end

        @impl true
        def clear(collection, opts) do
          # Your implementation
        end
      end

  Then configure:

      config :arcana, vector_store: MyApp.CustomVectorStore

  """

  alias Arcana.VectorStore.{Memory, Pgvector}

  @type collection :: String.t()
  @type id :: String.t()
  @type embedding :: [float()]
  @type metadata :: map()
  @type search_result :: %{id: id(), metadata: metadata(), score: float()}

  @doc """
  Stores a vector with its id and metadata in a collection.
  """
  @callback store(collection(), id(), embedding(), metadata(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Searches for similar vectors in a collection.

  Returns a list of results with `:id`, `:metadata`, and `:score` keys.
  """
  @callback search(collection(), embedding(), opts :: keyword()) :: [search_result()]

  @doc """
  Deletes a vector from a collection.
  """
  @callback delete(collection(), id(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  Clears all vectors from a collection.
  """
  @callback clear(collection(), opts :: keyword()) :: :ok

  # Dispatch Functions

  @doc """
  Returns the configured vector store backend.

  ## Examples

      iex> Arcana.VectorStore.backend()
      :pgvector

  """
  def backend do
    Application.get_env(:arcana, :vector_store, :pgvector)
  end

  @doc """
  Stores a vector using the configured backend.

  ## Options

    * `:repo` - The Ecto repo (required for pgvector backend)
    * `:server` - The Memory server pid/name (for memory backend, defaults to `Arcana.VectorStore.Memory`)

  """
  def store(collection, id, embedding, metadata, opts \\ []) do
    case backend() do
      :pgvector ->
        Pgvector.store(collection, id, embedding, metadata, opts)

      :memory ->
        server = Keyword.get(opts, :server, Memory)
        Memory.store(server, collection, id, embedding, metadata)

      module when is_atom(module) ->
        module.store(collection, id, embedding, metadata, opts)
    end
  end

  @doc """
  Searches for similar vectors using the configured backend.

  ## Options

    * `:limit` - Maximum number of results (default: 10)
    * `:repo` - The Ecto repo (required for pgvector backend)
    * `:server` - The Memory server pid/name (for memory backend)

  """
  def search(collection, query_embedding, opts \\ []) do
    case backend() do
      :pgvector ->
        Pgvector.search(collection, query_embedding, opts)

      :memory ->
        server = Keyword.get(opts, :server, Memory)
        Memory.search(server, collection, query_embedding, opts)

      module when is_atom(module) ->
        module.search(collection, query_embedding, opts)
    end
  end

  @doc """
  Deletes a vector using the configured backend.
  """
  def delete(collection, id, opts \\ []) do
    case backend() do
      :pgvector ->
        Pgvector.delete(collection, id, opts)

      :memory ->
        server = Keyword.get(opts, :server, Memory)
        Memory.delete(server, collection, id)

      module when is_atom(module) ->
        module.delete(collection, id, opts)
    end
  end

  @doc """
  Clears a collection using the configured backend.
  """
  def clear(collection, opts \\ []) do
    case backend() do
      :pgvector ->
        Pgvector.clear(collection, opts)

      :memory ->
        server = Keyword.get(opts, :server, Memory)
        Memory.clear(server, collection)

      module when is_atom(module) ->
        module.clear(collection, opts)
    end
  end
end
