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

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, answer} -> {:ok, String.trim(answer)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question, chunks) do
    reference_material = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    """
    Reference material:
    #{reference_material}

    Question: "#{question}"

    Answer the question directly and naturally. Use the reference material to inform your answer, but don't mention or reference it explicitly. If you don't have enough information to answer, simply say you don't know.
    """
  end
end
