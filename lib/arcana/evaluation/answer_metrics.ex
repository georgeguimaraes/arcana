defmodule Arcana.Evaluation.AnswerMetrics do
  @moduledoc """
  Evaluates answer quality using LLM-as-judge.

  Provides faithfulness scoring to measure whether generated answers
  are grounded in the retrieved context.
  """

  alias Arcana.LLM

  @default_prompt """
  You are evaluating whether an answer is faithful to the provided context.

  Question: {question}

  Context (retrieved chunks):
  {chunks}

  Answer to evaluate:
  {answer}

  Rate the faithfulness of this answer on a scale of 0-10:
  - 0: Completely unfaithful, hallucinated, or contradicts the context
  - 5: Partially supported, some claims lack grounding
  - 10: Fully faithful, every claim is supported by the context

  Respond with JSON only:
  {"score": <0-10>, "reasoning": "<brief explanation>"}
  """

  @doc """
  Returns the default faithfulness prompt template.
  """
  def default_prompt, do: @default_prompt

  @doc """
  Evaluates the faithfulness of an answer to the retrieved chunks.

  ## Options

    * `:llm` - LLM function (required)
    * `:prompt` - Custom prompt function `fn question, chunks, answer -> prompt end`

  ## Returns

    * `{:ok, %{score: integer, reasoning: string | nil}}` on success
    * `{:error, reason}` on failure

  """
  def evaluate_faithfulness(question, chunks, answer, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt, &default_prompt_fn/3)

    prompt = prompt_fn.(question, chunks, answer)

    case LLM.complete(llm, prompt, []) do
      {:ok, response} -> parse_response(response)
      {:error, _} = err -> err
    end
  end

  defp default_prompt_fn(question, chunks, answer) do
    chunks_text = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    @default_prompt
    |> String.replace("{question}", question)
    |> String.replace("{chunks}", chunks_text)
    |> String.replace("{answer}", answer)
  end

  defp parse_response(response) do
    case Jason.decode(response) do
      {:ok, %{"score" => score} = data} when is_number(score) ->
        {:ok,
         %{
           score: clamp_score(score),
           reasoning: data["reasoning"]
         }}

      {:ok, _} ->
        {:error, :invalid_response}

      {:error, _} ->
        {:error, :invalid_response}
    end
  end

  defp clamp_score(score) when score < 0, do: 0
  defp clamp_score(score) when score > 10, do: 10
  defp clamp_score(score), do: score
end
