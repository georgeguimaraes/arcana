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
  Searches for similar vectors in a collection (semantic search).

  Returns a list of results with `:id`, `:metadata`, and `:score` keys.
  """
  @callback search(collection(), embedding(), opts :: keyword()) :: [search_result()]

  @doc """
  Searches for matching text in a collection (fulltext search).

  Returns a list of results with `:id`, `:metadata`, and `:score` keys.
  Score represents relevance based on term matching.
  """
  @callback search_text(collection(), query :: String.t(), opts :: keyword()) :: [search_result()]

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

    * `:vector_store` - Override the configured backend. Can be:
      * `{:memory, pid: pid}` - Use memory backend with specific server
      * `{:pgvector, repo: MyRepo}` - Use pgvector with specific repo
      * `MyCustomModule` - Use a custom module implementing the behaviour
    * `:limit` - Maximum number of results (default: 10)

  ## Examples

      # Use global config
      VectorStore.store("products", "id", embedding, metadata)

      # Override with memory backend
      VectorStore.store("products", "id", embedding, metadata,
        vector_store: {:memory, pid: memory_pid})

      # Override with pgvector backend
      VectorStore.store("products", "id", embedding, metadata,
        vector_store: {:pgvector, repo: MyApp.Repo})

  """
  def store(collection, id, embedding, metadata, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span([:arcana, :vector_store, :store], %{collection: collection, id: id}, fn ->
      result = dispatch(:store, backend, [collection, id, embedding, metadata], backend_opts, opts)
      {result, %{backend: backend}}
    end)
  end

  @doc """
  Searches for similar vectors using the configured backend.

  ## Options

    * `:vector_store` - Override the configured backend (see `store/5` for format)
    * `:limit` - Maximum number of results (default: 10)

  ## Examples

      # Use global config
      VectorStore.search("products", query_embedding, limit: 10)

      # Override with memory backend
      VectorStore.search("products", query_embedding,
        vector_store: {:memory, pid: memory_pid},
        limit: 10)

  """
  def search(collection, query_embedding, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    limit = Keyword.get(opts, :limit, 10)

    :telemetry.span(
      [:arcana, :vector_store, :search],
      %{collection: collection, limit: limit},
      fn ->
        results = dispatch(:search, backend, [collection, query_embedding], backend_opts, opts)
        {results, %{backend: backend, result_count: length(results)}}
      end
    )
  end

  @doc """
  Searches for matching text using the configured backend (fulltext search).

  ## Options

    * `:vector_store` - Override the configured backend (see `store/5` for format)
    * `:limit` - Maximum number of results (default: 10)

  ## Examples

      # Use global config
      VectorStore.search_text("products", "organic coffee", limit: 10)

      # Override with memory backend
      VectorStore.search_text("products", "organic coffee",
        vector_store: {:memory, pid: memory_pid},
        limit: 10)

  """
  def search_text(collection, query_text, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)
    limit = Keyword.get(opts, :limit, 10)

    :telemetry.span(
      [:arcana, :vector_store, :search_text],
      %{collection: collection, query: query_text, limit: limit},
      fn ->
        results = dispatch(:search_text, backend, [collection, query_text], backend_opts, opts)
        {results, %{backend: backend, result_count: length(results)}}
      end
    )
  end

  @doc """
  Deletes a vector using the configured backend.

  ## Options

    * `:vector_store` - Override the configured backend (see `store/5` for format)

  """
  def delete(collection, id, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span([:arcana, :vector_store, :delete], %{collection: collection, id: id}, fn ->
      result = dispatch(:delete, backend, [collection, id], backend_opts, opts)
      {result, %{backend: backend}}
    end)
  end

  @doc """
  Clears a collection using the configured backend.

  ## Options

    * `:vector_store` - Override the configured backend (see `store/5` for format)

  """
  def clear(collection, opts \\ []) do
    {backend, backend_opts, opts} = extract_backend(opts)

    :telemetry.span([:arcana, :vector_store, :clear], %{collection: collection}, fn ->
      result = dispatch(:clear, backend, [collection], backend_opts, opts)
      {result, %{backend: backend}}
    end)
  end

  # Extract backend and its options from opts
  defp extract_backend(opts) do
    {vector_store, opts} = Keyword.pop(opts, :vector_store, backend())

    case vector_store do
      {backend, backend_opts} when is_atom(backend) and is_list(backend_opts) ->
        {backend, backend_opts, opts}

      backend when is_atom(backend) ->
        {backend, [], opts}
    end
  end

  # Dispatch to memory backend
  defp dispatch(:store, :memory, [collection, id, embedding, metadata], backend_opts, _opts) do
    pid = Keyword.get(backend_opts, :pid, Memory)
    Memory.store(pid, collection, id, embedding, metadata)
  end

  defp dispatch(:search, :memory, [collection, query_embedding], backend_opts, opts) do
    pid = Keyword.get(backend_opts, :pid, Memory)
    Memory.search(pid, collection, query_embedding, opts)
  end

  defp dispatch(:search_text, :memory, [collection, query_text], backend_opts, opts) do
    pid = Keyword.get(backend_opts, :pid, Memory)
    Memory.search_text(pid, collection, query_text, opts)
  end

  defp dispatch(:delete, :memory, [collection, id], backend_opts, _opts) do
    pid = Keyword.get(backend_opts, :pid, Memory)
    Memory.delete(pid, collection, id)
  end

  defp dispatch(:clear, :memory, [collection], backend_opts, _opts) do
    pid = Keyword.get(backend_opts, :pid, Memory)
    Memory.clear(pid, collection)
  end

  # Dispatch to pgvector backend
  defp dispatch(:store, :pgvector, [collection, id, embedding, metadata], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    Pgvector.store(collection, id, embedding, metadata, opts)
  end

  defp dispatch(:search, :pgvector, [collection, query_embedding], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    Pgvector.search(collection, query_embedding, opts)
  end

  defp dispatch(:search_text, :pgvector, [collection, query_text], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    Pgvector.search_text(collection, query_text, opts)
  end

  defp dispatch(:delete, :pgvector, [collection, id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    Pgvector.delete(collection, id, opts)
  end

  defp dispatch(:clear, :pgvector, [collection], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    Pgvector.clear(collection, opts)
  end

  # Dispatch to custom module
  defp dispatch(:store, module, [collection, id, embedding, metadata], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.store(collection, id, embedding, metadata, opts)
  end

  defp dispatch(:search, module, [collection, query_embedding], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.search(collection, query_embedding, opts)
  end

  defp dispatch(:search_text, module, [collection, query_text], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.search_text(collection, query_text, opts)
  end

  defp dispatch(:delete, module, [collection, id], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.delete(collection, id, opts)
  end

  defp dispatch(:clear, module, [collection], backend_opts, opts) do
    opts = Keyword.merge(backend_opts, opts)
    module.clear(collection, opts)
  end
end
