defmodule Arcana.Agent.Answerer do
  @moduledoc """
  Behaviour for answer generation in the Agent pipeline.

  The answerer generates the final response based on the question and
  retrieved context chunks.

  ## Built-in Implementations

  - `Arcana.Agent.Answerer.LLM` - Uses your LLM to generate answers (default)

  ## Implementing a Custom Answerer

      defmodule MyApp.TemplateAnswerer do
        @behaviour Arcana.Agent.Answerer

        @impl true
        def answer(question, chunks, _opts) do
          context = Enum.map_join(chunks, "\n", & &1.text)
          answer = "Based on " <> Integer.to_string(length(chunks)) <> " sources:\n\n" <> context
          {:ok, answer}
        end
      end

  ## Using a Custom Answerer

      Agent.new(question, repo: repo, llm: llm)
      |> Agent.search()
      |> Agent.answer(answerer: MyApp.TemplateAnswerer)

  ## Using an Inline Function

      Agent.answer(ctx,
        answerer: fn question, chunks, opts ->
          llm = Keyword.fetch!(opts, :llm)
          prompt = build_my_prompt(question, chunks)
          Arcana.LLM.complete(llm, prompt, [], [])
        end
      )
  """

  @doc """
  Generates an answer based on the question and context chunks.

  ## Parameters

  - `question` - The user's original question
  - `chunks` - List of context chunks retrieved by search
  - `opts` - Options passed to `Agent.answer/2`, including:
    - `:llm` - The LLM function (for LLM-based answerers)
    - `:prompt` - Custom prompt function `fn question, chunks -> prompt end`
    - Any other options passed to `Agent.answer/2`

  ## Returns

  - `{:ok, answer}` - The generated answer string
  - `{:error, reason}` - On failure
  """
  @callback answer(
              question :: String.t(),
              chunks :: [map()],
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}
end
