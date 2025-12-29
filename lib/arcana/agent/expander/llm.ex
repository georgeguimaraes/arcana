defmodule Arcana.Agent.Expander.LLM do
  @moduledoc """
  LLM-based query expander.

  Uses the configured LLM to add synonyms and related terms to queries.
  This is the default expander used by `Agent.expand/2`.

  ## Usage

      # With Agent pipeline (uses ctx.llm automatically)
      ctx
      |> Agent.expand()
      |> Agent.search()
      |> Agent.answer()

      # Directly
      {:ok, expanded} = Arcana.Agent.Expander.LLM.expand(
        "ML models",
        llm: &my_llm/1
      )
  """

  @behaviour Arcana.Agent.Expander

  @default_prompt """
  You are a search query expansion assistant. Your task is to expand the user's query with synonyms and related terms to improve document retrieval.

  Rules:
  - Keep ALL original terms from the query
  - Add synonyms and related terms that convey the same meaning
  - Expand abbreviations and acronyms (e.g., "ML" → "ML machine learning")
  - Do NOT remove or replace technical terms you don't recognize
  - Return a single expanded query string, nothing else

  Examples:
  Query: "ML models for NLP"
  Expanded: "ML machine learning models for NLP natural language processing text analysis"

  Query: "remote work productivity"
  Expanded: "remote work telecommuting working from home productivity efficiency performance"

  Query: "Phoenix LiveView real-time"
  Expanded: "Phoenix LiveView real-time live updates websocket server-rendered interactive"

  Now expand this query:
  "{query}"
  """

  @impl Arcana.Agent.Expander
  def expand(question, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question)
        custom_fn -> custom_fn.(question)
      end

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, expanded} -> {:ok, String.trim(expanded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question) do
    String.replace(@default_prompt, "{query}", question)
  end
end
