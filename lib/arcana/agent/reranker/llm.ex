defmodule Arcana.Agent.Reranker.LLM do
  @moduledoc """
  LLM-based re-ranker that uses your configured LLM to score chunk relevance.

  Scores each chunk from 0-10 based on relevance to the question,
  then filters by threshold and sorts by score.

  ## Usage

      # With Agent pipeline (uses ctx.llm automatically)
      ctx
      |> Agent.search()
      |> Agent.rerank()
      |> Agent.answer()

      # Directly
      {:ok, reranked} = Arcana.Agent.Reranker.LLM.rerank(
        "What is Elixir?",
        chunks,
        llm: &my_llm/1,
        threshold: 7
      )
  """

  @behaviour Arcana.Agent.Reranker

  @default_threshold 7

  @default_prompt_template """
  Rate how relevant this text is for answering the question.

  Question: {question}

  Text: {chunk_text}

  Return JSON only: {"score": <0-10>, "reasoning": "..."}
  - 10 = directly answers the question
  - 7-9 = highly relevant context
  - 4-6 = somewhat relevant
  - 0-3 = not relevant
  """

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    llm = Keyword.fetch!(opts, :llm)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    prompt_fn = Keyword.get(opts, :prompt)

    scored_chunks =
      chunks
      |> Enum.map(fn chunk ->
        prompt = build_prompt(question, chunk.text, prompt_fn)
        score = get_score(llm, prompt)
        {chunk, score}
      end)
      |> Enum.filter(fn {_chunk, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
      |> Enum.map(fn {chunk, _score} -> chunk end)

    {:ok, scored_chunks}
  end

  defp build_prompt(question, chunk_text, nil) do
    @default_prompt_template
    |> String.replace("{question}", question)
    |> String.replace("{chunk_text}", chunk_text)
  end

  defp build_prompt(question, chunk_text, prompt_fn) when is_function(prompt_fn, 2) do
    prompt_fn.(question, chunk_text)
  end

  defp get_score(llm, prompt) do
    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, response} -> parse_score(response)
      {:error, _} -> 0
    end
  end

  defp parse_score(response) do
    case JSON.decode(response) do
      {:ok, %{"score" => score}} when is_number(score) -> score
      _ -> 0
    end
  end
end
