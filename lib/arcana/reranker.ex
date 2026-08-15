defmodule Arcana.Reranker do
  @moduledoc """
  Behaviour for re-ranking search results.

  Re-rankers improve retrieval quality by scoring chunks based on their
  relevance to the question, then filtering and re-sorting by score.

  ## Built-in Implementations

  - `Arcana.Reranker.LLM` - Uses your LLM to score relevance (default)

  ## Custom Implementations

  Implement the `rerank/3` callback:

      defmodule MyApp.CrossEncoderReranker do
        @behaviour Arcana.Reranker

        @impl Arcana.Reranker
        def rerank(question, chunks, opts) do
          # Your custom logic
          {:ok, scored_and_filtered_chunks}
        end
      end

  Or provide a function directly:

      Pipeline.rerank(ctx, reranker: fn question, chunks, opts ->
        {:ok, my_rerank(question, chunks)}
      end)
  """

  @doc """
  Re-ranks chunks based on relevance to the question.

  Chunks are `Arcana.SearchResult` structs. Returns chunks filtered by
  threshold and sorted by score (highest first). Rerankers that compute
  an explicit score should store it in the `:rerank_score` field (as
  `Arcana.Reranker.ColBERT` does); rerankers that only reorder or filter
  can return the chunks unchanged.

  ## Options

  - `:threshold` - Minimum score to keep (default: 7, range 0-10)
  - `:llm` - LLM function for scoring (required for LLM reranker)
  - `:prompt` - Custom prompt function `fn question, chunk_text -> prompt end`
  """
  @callback rerank(
              question :: String.t(),
              chunks :: [Arcana.SearchResult.t()],
              opts :: keyword()
            ) :: {:ok, [Arcana.SearchResult.t()]} | {:error, term()}
end
