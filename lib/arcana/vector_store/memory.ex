defmodule Arcana.VectorStore.Memory do
  @moduledoc """
  In-memory vector store using HNSWLib for approximate nearest neighbor search.

  Useful for:
  - Testing embedding models without database migrations
  - Smaller RAGs where pgvector overhead isn't justified
  - Development and experimentation workflows

  ## Usage

      # Start the server
      {:ok, pid} = Arcana.VectorStore.Memory.start_link(name: MyApp.VectorStore)

      # Store vectors
      :ok = Memory.store(pid, "default", "chunk-1", embedding, %{text: "hello"})

      # Search
      results = Memory.search(pid, "default", query_embedding, limit: 10)

      # Delete
      :ok = Memory.delete(pid, "default", "chunk-1")

      # Clear collection
      :ok = Memory.clear(pid, "default")

  ## Notes

  - Data is not persisted to disk - all vectors are lost when the process stops
  - Uses cosine similarity for semantic search
  - Recommended for < 100K vectors per collection
  """

  use GenServer

  @default_max_elements 10_000

  # Client API

  @doc """
  Starts the Memory vector store GenServer.

  ## Options

    * `:name` - The name to register the GenServer under (optional)
    * `:max_elements` - Maximum number of elements per collection (default: 10,000)

  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores a vector with its id and metadata in a collection.

  ## Parameters

    * `server` - The GenServer pid or name
    * `collection` - The collection name (e.g., "default", "products")
    * `id` - Unique identifier for the vector
    * `embedding` - The embedding vector as a list of floats
    * `metadata` - A map of metadata associated with the vector

  ## Returns

    * `:ok` on success

  """
  def store(server, collection, id, embedding, metadata) do
    GenServer.call(server, {:store, collection, id, embedding, metadata})
  end

  @doc """
  Searches for similar vectors in a collection.

  ## Parameters

    * `server` - The GenServer pid or name
    * `collection` - The collection name to search in
    * `query_embedding` - The query vector as a list of floats
    * `opts` - Search options
      * `:limit` - Maximum number of results to return (default: 10)

  ## Returns

  A list of maps with keys:
    * `:id` - The vector's unique identifier
    * `:metadata` - The associated metadata map
    * `:score` - Similarity score (0.0 to 1.0, higher is more similar)

  """
  def search(server, collection, query_embedding, opts \\ []) do
    GenServer.call(server, {:search, collection, query_embedding, opts})
  end

  @doc """
  Searches for matching text in a collection (fulltext search).

  Uses simple term matching with TF-IDF-like scoring.

  ## Parameters

    * `server` - The GenServer pid or name
    * `collection` - The collection name to search in
    * `query_text` - The query string
    * `opts` - Search options
      * `:limit` - Maximum number of results to return (default: 10)

  ## Returns

  A list of maps with keys:
    * `:id` - The vector's unique identifier
    * `:metadata` - The associated metadata map
    * `:score` - Relevance score based on term matching (higher is more relevant)

  """
  def search_text(server, collection, query_text, opts \\ []) do
    GenServer.call(server, {:search_text, collection, query_text, opts})
  end

  @doc """
  Deletes a vector from a collection.

  ## Parameters

    * `server` - The GenServer pid or name
    * `collection` - The collection name
    * `id` - The vector's unique identifier

  ## Returns

    * `:ok` on success
    * `{:error, :not_found}` if the id doesn't exist in the collection

  """
  def delete(server, collection, id) do
    GenServer.call(server, {:delete, collection, id})
  end

  @doc """
  Clears all vectors from a collection.

  ## Parameters

    * `server` - The GenServer pid or name
    * `collection` - The collection name to clear

  ## Returns

    * `:ok` on success

  """
  def clear(server, collection) do
    GenServer.call(server, {:clear, collection})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    max_elements = Keyword.get(opts, :max_elements, @default_max_elements)

    {:ok, %{collections: %{}, max_elements: max_elements, dimensions: nil}}
  end

  @impl true
  def handle_call({:store, collection, id, embedding, metadata}, _from, state) do
    dims = length(embedding)
    state = ensure_dimensions(state, dims)

    {collection_data, state} = get_or_create_collection(state, collection, dims)

    # Check if id already exists - if so, mark old one as deleted
    collection_data =
      case Enum.find_index(collection_data.ids, &(&1 == id)) do
        nil ->
          collection_data

        existing_idx ->
          %{collection_data | deleted: MapSet.put(collection_data.deleted, existing_idx)}
      end

    # Add to index
    tensor = Nx.tensor([embedding], type: :f32)
    :ok = HNSWLib.Index.add_items(collection_data.index, tensor)

    # Track id and metadata
    collection_data = %{
      collection_data
      | ids: collection_data.ids ++ [id],
        metadata: collection_data.metadata ++ [metadata]
    }

    state = put_in(state, [:collections, collection], collection_data)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:search, collection, query_embedding, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    case get_in(state, [:collections, collection]) do
      nil ->
        {:reply, [], state}

      %{index: index, ids: ids, metadata: metas, deleted: deleted} ->
        # Get more results than needed to account for deleted items
        k = min(limit + MapSet.size(deleted), length(ids))

        if k == 0 do
          {:reply, [], state}
        else
          query = Nx.tensor([query_embedding], type: :f32)
          {:ok, labels, distances} = HNSWLib.Index.knn_query(index, query, k: k)

          # Map labels back to ids and metadata, filtering deleted
          results =
            labels
            |> Nx.to_flat_list()
            |> Enum.zip(Nx.to_flat_list(distances))
            |> Enum.reject(fn {idx, _distance} -> MapSet.member?(deleted, idx) end)
            |> Enum.take(limit)
            |> Enum.map(fn {idx, distance} ->
              %{
                id: Enum.at(ids, idx),
                metadata: Enum.at(metas, idx),
                score: 1.0 - distance
              }
            end)

          {:reply, results, state}
        end
    end
  end

  @impl true
  def handle_call({:search_text, collection, query_text, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    case get_in(state, [:collections, collection]) do
      nil ->
        {:reply, [], state}

      %{ids: ids, metadata: metas, deleted: deleted} ->
        # Tokenize query
        query_terms = tokenize(query_text)

        if Enum.empty?(query_terms) do
          {:reply, [], state}
        else
          # Score each document by term matching
          results =
            ids
            |> Enum.with_index()
            |> Enum.reject(fn {_id, idx} -> MapSet.member?(deleted, idx) end)
            |> Enum.map(fn {id, idx} ->
              meta = Enum.at(metas, idx)
              text = meta[:text] || ""
              score = calculate_text_score(query_terms, text)
              {id, meta, score, idx}
            end)
            |> Enum.filter(fn {_id, _meta, score, _idx} -> score > 0 end)
            |> Enum.sort_by(fn {_id, _meta, score, _idx} -> score end, :desc)
            |> Enum.take(limit)
            |> Enum.map(fn {id, meta, score, _idx} ->
              %{id: id, metadata: meta, score: score}
            end)

          {:reply, results, state}
        end
    end
  end

  @impl true
  def handle_call({:delete, collection, id}, _from, state) do
    case get_in(state, [:collections, collection]) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{ids: ids, deleted: deleted} = collection_data ->
        case Enum.find_index(ids, &(&1 == id)) do
          nil ->
            {:reply, {:error, :not_found}, state}

          idx ->
            if MapSet.member?(deleted, idx) do
              {:reply, {:error, :not_found}, state}
            else
              collection_data = %{collection_data | deleted: MapSet.put(deleted, idx)}
              state = put_in(state, [:collections, collection], collection_data)
              {:reply, :ok, state}
            end
        end
    end
  end

  @impl true
  def handle_call({:clear, collection}, _from, state) do
    dims = state.dimensions || 384
    {:ok, index} = HNSWLib.Index.new(:cosine, dims, state.max_elements)

    collection_data = %{
      index: index,
      ids: [],
      metadata: [],
      deleted: MapSet.new()
    }

    state = put_in(state, [:collections, collection], collection_data)
    {:reply, :ok, state}
  end

  # Private Functions

  defp ensure_dimensions(%{dimensions: nil} = state, dims) do
    %{state | dimensions: dims}
  end

  defp ensure_dimensions(state, _dims), do: state

  defp get_or_create_collection(state, collection, dims) do
    case get_in(state, [:collections, collection]) do
      nil ->
        {:ok, index} = HNSWLib.Index.new(:cosine, dims, state.max_elements)

        collection_data = %{
          index: index,
          ids: [],
          metadata: [],
          deleted: MapSet.new()
        }

        {collection_data, put_in(state, [:collections, collection], collection_data)}

      existing ->
        {existing, state}
    end
  end

  # Tokenize text into lowercase terms
  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.uniq()
  end

  # Calculate TF-IDF-like score: (matching terms / query terms) * (1 / log(doc_length))
  defp calculate_text_score(query_terms, text) do
    doc_terms = tokenize(text)

    if Enum.empty?(doc_terms) do
      0.0
    else
      matching = Enum.count(query_terms, fn term -> term in doc_terms end)

      if matching == 0 do
        0.0
      else
        # Normalize by query length and penalize very short/long documents
        term_ratio = matching / length(query_terms)
        # Simple length normalization
        length_factor = 1.0 / :math.log(max(length(doc_terms), 2) + 1)
        term_ratio * length_factor
      end
    end
  end
end
