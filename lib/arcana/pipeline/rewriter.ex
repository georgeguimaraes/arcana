defmodule Arcana.Pipeline.Rewriter do
  @moduledoc """
  Behaviour for query rewriting in the Agent pipeline.

  The rewriter transforms conversational input into clear search queries
  by removing filler phrases, greetings, and other noise while preserving
  the core question and important terms.

  ## Built-in Implementations

  - `Arcana.Pipeline.Rewriter.LLM` - Uses your LLM to rewrite queries (default)

  ## Implementing a Custom Rewriter

      defmodule MyApp.RegexRewriter do
        @behaviour Arcana.Pipeline.Rewriter

        @impl true
        def rewrite(question, _opts) do
          cleaned =
            question
            |> String.replace(~r/^(hey|hi|hello)[,!]?\\s*/i, "")
            |> String.replace(~r/^(can you|could you|please)\\s+/i, "")
            |> String.trim()

          {:ok, cleaned}
        end
      end

  ## Using a Custom Rewriter

      Pipeline.new(question, repo: repo, llm: llm)
      |> Pipeline.rewrite(rewriter: MyApp.RegexRewriter)
      |> Pipeline.search()

  ## Using an Inline Function

      Pipeline.rewrite(ctx,
        rewriter: fn question, _opts ->
          {:ok, String.downcase(question)}
        end
      )
  """

  @doc """
  Rewrites a conversational query into a clear search query.

  ## Parameters

  - `question` - The user's original question
  - `opts` - Options passed to `Pipeline.rewrite/2`, including:
    - `:llm` - The LLM function (for LLM-based rewriters)
    - `:prompt` - Custom prompt function (for LLM-based rewriters)
    - Any other options passed to `Pipeline.rewrite/2`

  ## Returns

  - `{:ok, rewritten_query}` - The cleaned query string
  - `{:error, reason}` - On failure, the original question is used
  """
  @callback rewrite(
              question :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}
end
