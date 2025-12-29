defmodule Arcana.Agent.Answerer.LLM do
  @moduledoc """
  LLM-based answer generator.

  Uses the configured LLM to generate answers from retrieved context.
  This is the default answerer used by `Agent.answer/2`.

  ## Usage

      # With Agent pipeline (uses ctx.llm automatically)
      ctx
      |> Agent.search()
      |> Agent.answer()

      # Directly
      {:ok, answer} = Arcana.Agent.Answerer.LLM.answer(
        "What is Elixir?",
        chunks,
        llm: &my_llm/1
      )

  ## Custom Prompts

      Agent.answer(ctx,
        prompt: fn question, chunks ->
          context = Enum.map_join(chunks, "\n", & &1.text)
          "Answer: " <> question <> "\n\nContext: " <> context
        end
      )
  """

  @behaviour Arcana.Agent.Answerer

  @impl Arcana.Agent.Answerer
  def answer(question, chunks, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question, chunks)
        custom_fn -> custom_fn.(question, chunks)
      end

    case llm.(prompt) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question, chunks) do
    context = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    """
    Question: "#{question}"

    Context:
    #{context}

    Answer the question based on the context provided. If the context doesn't contain enough information, say so.
    """
  end
end
