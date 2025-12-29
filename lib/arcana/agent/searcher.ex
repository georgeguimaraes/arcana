defmodule Arcana.Agent.Searcher do
  @moduledoc """
  Behaviour for search execution in the Agent pipeline.

  The searcher retrieves relevant chunks from a knowledge base based on the query.
  This allows swapping Arcana's built-in pgvector search for any search backend.

  ## Built-in Implementations

  - `Arcana.Agent.Searcher.Arcana` - Uses Arcana's pgvector search (default)

  ## Implementing a Custom Searcher

      defmodule MyApp.ElasticsearchSearcher do
        @behaviour Arcana.Agent.Searcher

        @impl true
        def search(question, collection, opts) do
          limit = Keyword.get(opts, :limit, 5)

          # Your Elasticsearch query
          case Elasticsearch.search(collection, question, limit: limit) do
            {:ok, hits} ->
              chunks = Enum.map(hits, &to_chunk/1)
              {:ok, chunks}
            {:error, reason} ->
              {:error, reason}
          end
        end

        defp to_chunk(hit) do
          %{
            id: hit["_id"],
            text: hit["_source"]["content"],
            metadata: hit["_source"]["metadata"],
            similarity: hit["_score"]
          }
        end
      end

  ## Using a Custom Searcher

      Agent.new(question, repo: repo, llm: llm)
      |> Agent.search(searcher: MyApp.ElasticsearchSearcher)
      |> Agent.answer()

  ## Using an Inline Function

      Agent.search(ctx,
        searcher: fn question, collection, opts ->
          {:ok, my_search(question, collection, opts)}
        end
      )

  ## Chunk Format

  The searcher must return chunks as maps with at least these fields:

  - `:id` - Unique identifier for the chunk
  - `:text` - The text content
  - `:metadata` - Optional metadata map
  - `:similarity` - Optional similarity score (0.0-1.0)
  """

  @doc """
  Searches for relevant chunks matching the question.

  ## Parameters

  - `question` - The search query
  - `collection` - The collection name to search in
  - `opts` - Options passed to `Agent.search/2`, including:
    - `:repo` - The Ecto repo (for database-backed searchers)
    - `:limit` - Maximum chunks to return (default: 5)
    - `:threshold` - Minimum similarity threshold (default: 0.5)
    - Any other options passed to `Agent.search/2`

  ## Returns

  - `{:ok, chunks}` - List of chunk maps with :id, :text, :metadata, :similarity
  - `{:error, reason}` - On failure
  """
  @callback search(
              question :: String.t(),
              collection :: String.t(),
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, term()}
end
