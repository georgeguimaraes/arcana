defmodule Arcana.Reranker do
  @moduledoc """
  Behaviour for re-ranking search results.

  Re-rankers improve retrieval quality by scoring chunks based on their
  relevance to the question, then filtering and re-sorting by score.

  **No reranker runs unless you configure one.** There is no implicit default:
  with neither `config :arcana, reranker: ...` nor a `:reranker` option,
  `Arcana.search/2` returns its results unreranked, even when an LLM is
  configured for `Arcana.ask/2`.

      config :arcana, reranker: Arcana.Reranker.LLM        # every search
      Arcana.search(query, reranker: Arcana.Reranker.LLM)  # this search

  A module, or a `{module, opts}` tuple, or a three-arity function. There is no
  `:llm` shortcut - unlike `:embedder` and `:chunker`, the reranker spec defines
  none, so name the module.

  ## Reranking filters as well as reorders

  Worth knowing before you enable one: the callback returns chunks *filtered* by
  `:threshold` and sorted by score, so a chunk that was in the results can be
  absent afterwards rather than merely lower down. `:threshold` is therefore a
  recall-for-precision trade, not a display preference - if a relevant chunk
  disappears when you turn reranking on, lower it (or set it to 0 to reorder
  only).

  ## Built-in Implementations

  - `Arcana.Reranker.LLM` - uses your LLM to score relevance. Costs an LLM round
    trip per search, which is seconds rather than milliseconds - see its
    moduledoc before using it on an interactive path
  - `Arcana.Reranker.CrossEncoder` and `Arcana.Reranker.ColBERT` - local models,
    no LLM call

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

  Chunks from `Arcana.search/2` are `Arcana.SearchResult` structs, but
  custom `Arcana.Searcher` implementations may supply plain maps, so
  rerankers should not assume the struct. Returns chunks filtered by
  threshold and sorted by score (highest first). Rerankers that compute
  an explicit score store it under `:rerank_score` (all the built-in
  rerankers do); rerankers that only reorder or filter can return the
  chunks unchanged.

  ## Options

  - `:threshold` - Minimum score to keep (default: 7, range 0-10)
  - `:llm` - LLM function for scoring (required for LLM reranker)
  - `:prompt` - Custom prompt function `fn question, chunk_text -> prompt end`
  """
  @callback rerank(
              question :: String.t(),
              chunks :: [Arcana.SearchResult.t() | map()],
              opts :: keyword()
            ) :: {:ok, [Arcana.SearchResult.t() | map()]} | {:error, term()}
end
