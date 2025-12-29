defmodule Arcana.Agent.Selector.LLM do
  @moduledoc """
  LLM-based collection selector.

  Uses the configured LLM to analyze the question and available collections,
  then selects the most relevant ones to search. This is the default selector
  used by `Agent.select/2`.

  Collection descriptions are included in the prompt to help the LLM make
  better routing decisions.
  """

  @behaviour Arcana.Agent.Selector

  @impl true
  def select(question, collections, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_fn = Keyword.get(opts, :prompt)

    prompt =
      case prompt_fn do
        nil -> default_prompt(question, collections)
        custom_fn -> custom_fn.(question, collections)
      end

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, response} -> parse_response(response, collections)
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_prompt(question, collections) do
    collections_text = format_collections(collections)

    """
    Which collection(s) should be searched for this question?

    Question: "#{question}"

    Available collections:
    #{collections_text}

    Return JSON only: {"collections": ["name1", "name2"], "reasoning": "..."}
    Select only the most relevant collection(s). If unsure, include all.
    """
  end

  defp format_collections(collections) do
    Enum.map_join(collections, "\n", fn
      {name, nil} -> "- #{name}"
      {name, ""} -> "- #{name}"
      {name, description} -> "- #{name}: #{description}"
    end)
  end

  defp parse_response(response, collections) do
    fallback_names = Enum.map(collections, fn {name, _} -> name end)

    case JSON.decode(response) do
      {:ok, %{"collections" => cols, "reasoning" => reason}} when is_list(cols) ->
        {:ok, cols, reason}

      {:ok, %{"collections" => cols}} when is_list(cols) ->
        {:ok, cols, nil}

      _ ->
        {:ok, fallback_names, nil}
    end
  end
end
