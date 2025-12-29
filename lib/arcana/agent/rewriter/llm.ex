defmodule Arcana.Agent.Rewriter.LLM do
  @moduledoc """
  LLM-based query rewriter.

  Uses the configured LLM to transform conversational input into clear
  search queries. This is the default rewriter used by `Agent.rewrite/2`.

  ## Usage

      # With Agent pipeline (uses ctx.llm automatically)
      ctx
      |> Agent.rewrite()
      |> Agent.search()
      |> Agent.answer()

      # Directly
      {:ok, rewritten} = Arcana.Agent.Rewriter.LLM.rewrite(
        "Hey, can you tell me about Elixir?",
        llm: &my_llm/1
      )
  """

  @behaviour Arcana.Agent.Rewriter

  @default_prompt """
  You are a search query optimizer. Your task is to rewrite conversational user input into a clear, standalone search query.

  Rules:
  - Remove conversational filler (greetings, "I want to", "Can you tell me", "Hey", etc.)
  - Extract the core question or topic
  - Keep ALL entity names, technical terms, and specific details
  - Keep the query concise but complete
  - If the input is already a clear query, return it unchanged
  - Return only the rewritten query, nothing else

  Examples:
  Input: "Hey, so I was wondering if you could help me understand how Phoenix LiveView works"
  Rewritten: "how Phoenix LiveView works"

  Input: "I want to compare Elixir and Go lang for building web services"
  Rewritten: "compare Elixir and Go for building web services"

  Input: "Can you tell me about the advantages of using GenServer?"
  Rewritten: "advantages of using GenServer"

  Input: "What is pattern matching?"
  Rewritten: "What is pattern matching?"

  Now rewrite this input:
  "{query}"
  """

  @impl Arcana.Agent.Rewriter
  def rewrite(question, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question)
        custom_fn -> custom_fn.(question)
      end

    case llm.(prompt) do
      {:ok, rewritten} -> {:ok, String.trim(rewritten)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question) do
    String.replace(@default_prompt, "{query}", question)
  end
end
