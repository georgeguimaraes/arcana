defmodule Arcana.Agent.Decomposer do
  @moduledoc """
  Behaviour for query decomposition in the Agent pipeline.

  The decomposer breaks complex questions into simpler sub-questions
  that can be searched independently, improving retrieval for multi-faceted queries.

  ## Built-in Implementations

  - `Arcana.Agent.Decomposer.LLM` - Uses your LLM to decompose queries (default)

  ## Implementing a Custom Decomposer

      defmodule MyApp.KeywordDecomposer do
        @behaviour Arcana.Agent.Decomposer

        @impl true
        def decompose(question, _opts) do
          # Simple keyword-based decomposition
          sub_questions =
            question
            |> String.split(~r/\\s+(and|vs|versus|compared to)\\s+/i)
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          {:ok, sub_questions}
        end
      end

  ## Using a Custom Decomposer

      Agent.new(question, repo: repo, llm: llm)
      |> Agent.decompose(decomposer: MyApp.KeywordDecomposer)
      |> Agent.search()

  ## Using an Inline Function

      Agent.decompose(ctx,
        decomposer: fn question, _opts ->
          {:ok, [question]}  # No decomposition
        end
      )
  """

  @doc """
  Decomposes a complex question into simpler sub-questions.

  ## Parameters

  - `question` - The complex question to decompose
  - `opts` - Options passed to `Agent.decompose/2`, including:
    - `:llm` - The LLM function (for LLM-based decomposers)
    - `:prompt` - Custom prompt function (for LLM-based decomposers)
    - Any other options passed to `Agent.decompose/2`

  ## Returns

  - `{:ok, sub_questions}` - List of simpler questions
  - `{:error, reason}` - On failure, the original question is used as a single-item list
  """
  @callback decompose(
              question :: String.t(),
              opts :: keyword()
            ) :: {:ok, [String.t()]} | {:error, term()}
end
