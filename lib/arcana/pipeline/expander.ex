defmodule Arcana.Pipeline.Expander do
  @moduledoc """
  Behaviour for query expansion in the Agent pipeline.

  The expander adds synonyms, related terms, and alternative phrasings
  to improve document retrieval coverage.

  ## Built-in Implementations

  - `Arcana.Pipeline.Expander.LLM` - Uses your LLM to expand queries (default)

  ## Implementing a Custom Expander

      defmodule MyApp.ThesaurusExpander do
        @behaviour Arcana.Pipeline.Expander

        @impl true
        def expand(question, _opts) do
          expanded = question <> " " <> lookup_synonyms(question)
          {:ok, expanded}
        end

        defp lookup_synonyms(question) do
          # Your synonym lookup logic
          ""
        end
      end

  ## Using a Custom Expander

      Pipeline.new(question, repo: repo, llm: llm)
      |> Pipeline.expand(expander: MyApp.ThesaurusExpander)
      |> Pipeline.search()

  ## Using an Inline Function

      Pipeline.expand(ctx,
        expander: fn question, _opts ->
          {:ok, question <> " programming software development"}
        end
      )
  """

  @doc """
  Expands a query with synonyms and related terms.

  ## Parameters

  - `question` - The query to expand
  - `opts` - Options passed to `Pipeline.expand/2`, including:
    - `:llm` - The LLM function (for LLM-based expanders)
    - `:prompt` - Custom prompt function (for LLM-based expanders)
    - Any other options passed to `Pipeline.expand/2`

  ## Returns

  - `{:ok, expanded_query}` - The expanded query string
  - `{:error, reason}` - On failure, the original question is used
  """
  @callback expand(
              question :: String.t(),
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}
end
