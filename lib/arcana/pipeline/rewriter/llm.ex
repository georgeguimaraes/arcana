defmodule Arcana.Pipeline.Rewriter.LLM do
  @moduledoc """
  LLM-based query rewriter.

  Uses the configured LLM to transform conversational input into clear
  search queries. This is the default rewriter used by `Pipeline.rewrite/2`.

  ## Usage

      # With Arcana.Pipeline (uses ctx.llm automatically)
      ctx
      |> Pipeline.rewrite()
      |> Pipeline.search()
      |> Pipeline.answer()

      # Directly
      {:ok, rewritten} = Arcana.Pipeline.Rewriter.LLM.rewrite(
        "Hey, can you tell me about Elixir?",
        llm: &my_llm/1
      )
  """

  @behaviour Arcana.Pipeline.Rewriter

  @default_prompt """
  Rewrite a conversational user message into a clean search query. Output ONLY the rewritten query, no preamble, no quotes, no explanation.

  Strip everything that isn't the actual question:
  - Greetings: "Hey", "Hi", "So"
  - Softeners: "can you", "could you", "would you mind", "I was wondering"
  - Closings: "Thanks", "Thanks so much", "Appreciate it", "please help"
  - Politeness padding: "for your help", "on this", "if you don't mind"

  Keep:
  - The actual question or topic
  - All named entities, proper nouns, technical terms, specific details
  - Any domain-specific qualifiers that affect the answer

  If the input is already a clean query (no conversational wrapping), return it unchanged.

  Examples:
  Input: "Hey, can you tell me about Phoenix LiveView?"
  Rewritten: about Phoenix LiveView

  Input: "So I was wondering, who were the companions of the Doctor that died? Thanks so much for your help on this"
  Rewritten: companions of the Doctor that died

  Input: "Hi could you explain how GenServer handle_call works, appreciate it"
  Rewritten: how GenServer handle_call works

  Input: "I want to compare Elixir and Go for building web services"
  Rewritten: compare Elixir and Go for building web services

  Input: "What is pattern matching?"
  Rewritten: What is pattern matching?

  Now rewrite this input (remember: output ONLY the rewritten query):
  {query}
  """

  @impl Arcana.Pipeline.Rewriter
  def rewrite(question, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question)
        custom_fn -> custom_fn.(question)
      end

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, rewritten} -> {:ok, String.trim(rewritten)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question) do
    String.replace(@default_prompt, "{query}", question)
  end
end
