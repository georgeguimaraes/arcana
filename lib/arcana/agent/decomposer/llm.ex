defmodule Arcana.Agent.Decomposer.LLM do
  @moduledoc """
  LLM-based query decomposer.

  Uses the configured LLM to break complex questions into simpler sub-questions.
  This is the default decomposer used by `Agent.decompose/2`.

  ## Usage

      # With Agent pipeline (uses ctx.llm automatically)
      ctx
      |> Agent.decompose()
      |> Agent.search()
      |> Agent.answer()

      # Directly
      {:ok, sub_questions} = Arcana.Agent.Decomposer.LLM.decompose(
        "Compare Elixir and Go for web services",
        llm: &my_llm/1
      )
  """

  @behaviour Arcana.Agent.Decomposer

  @impl Arcana.Agent.Decomposer
  def decompose(question, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question)
        custom_fn -> custom_fn.(question)
      end

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, response} -> parse_response(response, question)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question) do
    """
    You are an AI assistant that breaks down complex questions into simpler sub-questions for a search system.

    Rules:
    - Generate 2-4 sub-questions that can be answered independently
    - Each sub-question should retrieve different information from the knowledge base
    - Do NOT rephrase acronyms or technical terms you don't recognize
    - If the question is already simple, return it unchanged

    Example:
    Question: "How does Phoenix LiveView compare to React for real-time features?"
    {"sub_questions": ["How does Phoenix LiveView handle real-time updates?", "How does React handle real-time updates?", "What are the performance characteristics of Phoenix LiveView?"]}

    Now decompose this question:
    "#{question}"

    Return JSON only: {"sub_questions": ["q1", "q2", ...]}
    """
  end

  defp parse_response(response, fallback_question) do
    # Try to extract JSON from the response (LLM might include extra text)
    json_string = extract_json(response)

    case JSON.decode(json_string) do
      {:ok, %{"sub_questions" => [_ | _] = questions}} ->
        {:ok, questions}

      {:ok, %{"subquestions" => [_ | _] = questions}} ->
        {:ok, questions}

      {:ok, %{"questions" => [_ | _] = questions}} ->
        {:ok, questions}

      _ ->
        # Fallback to original question if parsing fails
        {:ok, [fallback_question]}
    end
  end

  defp extract_json(response) do
    # Try to find JSON object in the response
    case Regex.run(~r/\{[^{}]*"(?:sub_questions|subquestions|questions)"[^{}]*\}/s, response) do
      [json] -> json
      _ -> response
    end
  end
end
