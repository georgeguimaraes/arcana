defmodule Arcana.Reranker.LLM do
  @moduledoc """
  LLM-based re-ranker that scores chunk relevance in a single batched call.

  Sends all chunks to the LLM in one prompt, gets back JSON scores (0-10),
  then filters by threshold and sorts by score descending.

  ## Cost

  One LLM call per search, on the critical path. Measured on a ~230 document
  collection at `limit: 8` with `over_fetch: 3`: 16-35 seconds per search against
  0.2-0.8 seconds unreranked. That is fine for a batch or background path and
  usually too slow for an interactive one - `Arcana.Reranker.CrossEncoder` and
  `Arcana.Reranker.ColBERT` score locally if you want reranking without the round
  trip.

  Also note the threshold filters: it defaults to 7, so chunks the LLM scores
  below that are dropped from the results rather than moved down. See
  `Arcana.Reranker` for what that trade means.

  ## Which LLM it uses

  In order: `:llm` in these opts (whether passed beside `:reranker` or inside its
  option list), then `config :arcana, llm: ...`. `Arcana.Pipeline` supplies
  `ctx.llm` through the first. It raises only when neither is set.

  ## Usage

      # With Arcana.Pipeline (uses ctx.llm automatically)
      ctx
      |> Pipeline.search()
      |> Pipeline.rerank()
      |> Pipeline.answer()

      # Directly
      {:ok, reranked} = Arcana.Reranker.LLM.rerank(
        "What is Elixir?",
        chunks,
        llm: &my_llm/1,
        threshold: 7
      )

  ## Custom prompt

  Pass a `:prompt` function with arity 2 receiving `(question, passages)` where
  passages is a list of `{id, chunk}` tuples:

      prompt_fn = fn question, passages ->
        # Build your own prompt using the question and passages
      end

      LLM.rerank("question", chunks, llm: llm, prompt: prompt_fn)
  """

  @behaviour Arcana.Reranker

  @default_threshold 7

  @impl Arcana.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    llm = resolve_llm!(opts)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    prompt_fn = Keyword.get(opts, :prompt)

    passages = chunks |> Enum.with_index(1) |> Enum.map(fn {chunk, idx} -> {idx, chunk} end)
    prompt = build_prompt(question, passages, prompt_fn)

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, response} ->
        {:ok, parse_scores(response, passages, threshold)}

      {:error, _} ->
        {:ok, chunks}
    end
  end

  # Falls back to the configured LLM the way Arcana.Ask does. Without this,
  # `search(reranker: {Arcana.Reranker.LLM, []})` raised KeyError on an app that
  # had an LLM configured all along, and the fix was to hand the library its own
  # LLM back - `llm: Arcana.Config.get([], :llm)`. Pipeline still supplies
  # ctx.llm through opts, and a per-call `llm:` still wins over config.
  defp resolve_llm!(opts) do
    case Arcana.Config.get(opts, :llm) do
      nil ->
        raise ArgumentError, """
        Arcana.Reranker.LLM needs an LLM and none was found.

        Configure one globally:

            config :arcana, llm: {MyApp.LLM, :complete}

        or pass it for this call, either beside :reranker or inside its opts:

            Arcana.search(query, reranker: {Arcana.Reranker.LLM, []}, llm: my_llm)
            Arcana.search(query, reranker: {Arcana.Reranker.LLM, llm: my_llm})
        """

      llm ->
        llm
    end
  end

  defp build_prompt(question, passages, nil) do
    passage_lines =
      passages
      |> Enum.map_join("\n", fn {idx, chunk} -> "[#{idx}] #{chunk.text}" end)

    """
    Rate how relevant each passage is for answering the question.

    Question: #{question}

    Passages:
    #{passage_lines}

    Return JSON only: {"1": <0-10>, "2": <0-10>, ...}
    Omit passages scoring below 4. Scores:
    - 10 = directly answers the question
    - 7-9 = highly relevant context
    - 4-6 = somewhat relevant
    - 0-3 = not relevant\
    """
  end

  defp build_prompt(question, passages, prompt_fn) when is_function(prompt_fn, 2) do
    prompt_fn.(question, passages)
  end

  defp extract_json(text) do
    trimmed = String.trim(text)

    cond do
      String.starts_with?(trimmed, "{") ->
        trimmed

      # Strip ```json ... ``` fences
      trimmed =~ ~r/```/ ->
        trimmed
        |> String.replace(~r/\A```(?:json)?\n?/, "")
        |> String.replace(~r/\n?```\z/, "")
        |> String.trim()

      # Extract first JSON object from preamble text
      true ->
        case Regex.run(~r/\{[^}]+\}/, trimmed) do
          [json] -> json
          _ -> trimmed
        end
    end
  end

  defp parse_scores(response, passages, threshold) do
    case response |> extract_json() |> JSON.decode() do
      {:ok, scores} when is_map(scores) ->
        passages
        |> Enum.map(fn {idx, chunk} ->
          score = Map.get(scores, to_string(idx), 0)
          {chunk, score}
        end)
        |> Enum.filter(fn {_chunk, score} -> is_number(score) and score >= threshold end)
        |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
        |> Enum.map(fn {chunk, score} -> Map.put(chunk, :rerank_score, score) end)

      _ ->
        Enum.map(passages, fn {_idx, chunk} -> chunk end)
    end
  end
end
