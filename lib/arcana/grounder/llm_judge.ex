defmodule Arcana.Grounder.LLMJudge do
  @moduledoc """
  LLM-as-judge grounder using atomic claim decomposition.

  Asks an LLM to decompose the answer into atomic factual claims and
  verify each claim against the retrieved chunks. Each claim comes back
  with a verdict (`supported`, `unsupported`, or `contradicted`) and the
  1-based indices of the chunks that support it. Claims are then mapped
  back to byte offsets in the answer for span-level highlighting.

  This follows the RAGAS faithfulness pattern: one structured-output LLM
  call instead of token-level NLI scoring. Compared to
  `Arcana.Grounder.Hallmark`, this grounder:

  - Does a single LLM call regardless of answer length or chunk count.
  - Uses semantic reasoning instead of token-overlap NLI, which handles
    paraphrase and synthesis better.
  - Returns chunk attribution directly from the LLM rather than via a
    secondary word-overlap pass.

  ## Requirements

  Requires `req_llm`. The judge model defaults to
  `Application.get_env(:arcana, :judge_model)`, falling back to
  `"anthropic:claude-haiku-4-5"`.

  ## Usage

      Pipeline.ground(ctx, grounder: Arcana.Grounder.LLMJudge)

      Loop.run(question, grounder: Arcana.Grounder.LLMJudge)

  ## Options

  - `:judge_model` - Model spec passed to ReqLLM. Defaults to
    `Application.get_env(:arcana, :judge_model, "anthropic:claude-haiku-4-5")`.
  - `:judge_temperature` - Sampling temperature. Defaults to `0.0` for
    deterministic verdicts.
  - `:judge_max_tokens` - Max output tokens. Defaults to `2048`.
  - `:judge_fn` - Override the LLM call entirely with a 3-arity function
    `(question, answer, chunks) -> {:ok, %{claims: [...]}} | {:error, term}`.
    Used for tests to avoid network calls.
  """

  @behaviour Arcana.Grounder

  alias Arcana.Grounding.Result

  @default_model "anthropic:claude-haiku-4-5"

  @impl Arcana.Grounder
  def ground(answer, chunks, opts) when is_binary(answer) do
    cond do
      String.trim(answer) == "" ->
        {:ok, %Result{score: 1.0}}

      chunks == [] ->
        {:ok, %Result{score: 0.0}}

      true ->
        question = Keyword.fetch!(opts, :question)

        case call_judge(question, answer, chunks, opts) do
          {:ok, %{claims: claims}} ->
            {:ok, build_result(answer, chunks, claims)}

          {:ok, _other} ->
            {:error, :invalid_judge_response}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp call_judge(question, answer, chunks, opts) do
    case Keyword.get(opts, :judge_fn) do
      fun when is_function(fun, 3) ->
        fun.(question, answer, chunks)

      nil ->
        try do
          call_req_llm(question, answer, chunks, opts)
        rescue
          e ->
            require Logger

            Logger.error(
              "[LLMJudge] grounder raised: " <> Exception.format(:error, e, __STACKTRACE__)
            )

            {:error, {:judge_raised, Exception.message(e)}}
        end
    end
  end

  defp call_req_llm(question, answer, chunks, opts) do
    unless Code.ensure_loaded?(ReqLLM) do
      raise """
      Arcana.Grounder.LLMJudge requires ReqLLM.

      Add to mix.exs:
        {:req_llm, "~> 1.6"}
      """
    end

    model =
      Keyword.get(opts, :judge_model) ||
        Application.get_env(:arcana, :judge_model, @default_model)

    temperature = Keyword.get(opts, :judge_temperature, 0.0)
    max_tokens = Keyword.get(opts, :judge_max_tokens, 2048)

    messages =
      ReqLLM.Context.new([
        ReqLLM.Context.system(system_prompt()),
        ReqLLM.Context.user(user_prompt(question, answer, chunks))
      ])

    reqllm_opts = [temperature: temperature, max_tokens: max_tokens]

    # Uses generate_text + JSON parsing rather than generate_object
    # because structured output support is uneven across providers
    # (e.g. ReqLLM 1.9 raises a KeyError when validating zai model specs
    # through generate_object's normalization path). Text generation
    # is the lowest-common-denominator path that works everywhere a
    # controller LLM already works.
    with {:ok, response} <- ReqLLM.generate_text(model, messages, reqllm_opts),
         text when is_binary(text) <- ReqLLM.Response.text(response),
         {:ok, parsed} <- parse_judge_json(text) do
      {:ok, parsed}
    else
      nil -> {:error, :empty_judge_response}
      {:error, reason} -> {:error, reason}
    end
  end

  # Extracts the first top-level JSON object from the model's text.
  # Models sometimes wrap JSON in prose ("Here's the result: { ... }"),
  # markdown fences, or a chain-of-thought preamble. We find the first
  # `{`, walk the string tracking brace depth (skipping string contents),
  # and decode whatever balanced region we find. If nothing parses, we
  # bail with :invalid_judge_response so Loop.ground swallows it.
  @doc false
  def parse_judge_json(text) do
    case extract_json_object(text) do
      nil ->
        {:error, :invalid_judge_response}

      json ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> {:ok, normalize_top_level(map)}
          _ -> {:error, :invalid_judge_response}
        end
    end
  end

  defp normalize_top_level(map) do
    %{claims: Map.get(map, "claims") || Map.get(map, :claims) || []}
  end

  defp extract_json_object(text) do
    case :binary.match(text, "{") do
      :nomatch -> nil
      {start, _} -> walk(text, start, start, 0, false, nil)
    end
  end

  # Tiny state machine: tracks depth of `{...}` pairs and whether we are
  # inside a string literal so braces in string values don't mess up the
  # count. Returns the balanced substring or nil if we hit the end first.
  defp walk(text, start, pos, depth, in_string?, escape?) do
    case :binary.part(text, pos, min(1, byte_size(text) - pos)) do
      "" ->
        nil

      <<char>> ->
        cond do
          escape? ->
            walk(text, start, pos + 1, depth, in_string?, false)

          in_string? and char == ?\\ ->
            walk(text, start, pos + 1, depth, true, true)

          in_string? and char == ?" ->
            walk(text, start, pos + 1, depth, false, false)

          in_string? ->
            walk(text, start, pos + 1, depth, true, false)

          char == ?" ->
            walk(text, start, pos + 1, depth, true, false)

          char == ?{ ->
            walk(text, start, pos + 1, depth + 1, false, false)

          char == ?} and depth == 1 ->
            :binary.part(text, start, pos + 1 - start)

          char == ?} ->
            walk(text, start, pos + 1, depth - 1, false, false)

          true ->
            walk(text, start, pos + 1, depth, in_string?, false)
        end
    end
  end

  defp system_prompt do
    """
    You are a precise faithfulness evaluator. Your job is to check whether an
    answer is grounded in a set of context chunks.

    Process:
    1. Decompose the answer into atomic factual claims. Each claim should be a
       single statement that can be independently verified. Quote the claim
       verbatim from the answer (preserve exact wording so it can be located
       in the answer).
    2. For each claim, decide its verdict against ONLY the provided chunks:
       - "supported": the claim is fully entailed by one or more chunks
       - "unsupported": the chunks do not say one way or the other
       - "contradicted": at least one chunk directly contradicts the claim
    3. For supported and contradicted claims, list the 1-based indices of the
       chunks involved.

    Rules:
    - General world knowledge ("the sky is blue") that the chunks don't
      mention should be marked "unsupported".
    - Skip purely stylistic content (greetings, transitions) that makes no
      factual claim.
    - Be strict: if a claim adds information not in the chunks, it is
      unsupported even if it sounds plausible.

    Output format: respond with a single JSON object and nothing else. No
    prose before or after. No markdown code fences. The object must have
    this exact shape:

    {
      "claims": [
        {
          "text": "verbatim claim from the answer",
          "verdict": "supported" | "unsupported" | "contradicted",
          "chunk_indices": [1, 2]
        }
      ]
    }
    """
  end

  defp user_prompt(question, answer, chunks) do
    formatted_chunks =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, idx} -> "[#{idx}] #{chunk_text(chunk)}" end)

    """
    ## Question
    #{question}

    ## Answer to Evaluate
    #{answer}

    ## Context Chunks
    #{formatted_chunks}
    """
  end

  defp chunk_text(%{text: text}) when is_binary(text), do: text
  defp chunk_text(%{"text" => text}) when is_binary(text), do: text
  defp chunk_text(_), do: ""

  defp build_result(_answer, _chunks, []) do
    %Result{score: 1.0}
  end

  defp build_result(answer, chunks, claims) do
    classified =
      claims
      |> Enum.map(&normalize_claim/1)
      |> Enum.reject(&(&1.text in [nil, ""]))

    if classified == [] do
      %Result{score: 1.0}
    else
      {supported, others} = Enum.split_with(classified, &(&1.verdict == :supported))
      score = length(supported) / length(classified)
      index_to_id = chunk_index_to_id_map(chunks)

      %Result{
        score: score,
        hallucinated_spans: Enum.flat_map(others, &claim_to_span(&1, answer, index_to_id)),
        faithful_spans: Enum.flat_map(supported, &claim_to_span(&1, answer, index_to_id))
      }
    end
  end

  defp normalize_claim(claim) do
    %{
      text: fetch(claim, :text),
      verdict: normalize_verdict(fetch(claim, :verdict)),
      chunk_indices: fetch(claim, :chunk_indices) || []
    }
  end

  defp fetch(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp normalize_verdict("supported"), do: :supported
  defp normalize_verdict("contradicted"), do: :contradicted
  defp normalize_verdict(_), do: :unsupported

  defp chunk_index_to_id_map(chunks) do
    chunks
    |> Enum.with_index(1)
    |> Map.new(fn {chunk, idx} -> {idx, chunk_id(chunk)} end)
  end

  defp chunk_id(%{id: id}), do: id
  defp chunk_id(%{"id" => id}), do: id
  defp chunk_id(_), do: nil

  defp claim_to_span(%{text: text} = claim, answer, index_to_id) do
    case :binary.match(answer, text) do
      :nomatch ->
        []

      {start, length} ->
        [
          %{
            text: text,
            start: start,
            end: start + length,
            score: 1.0,
            sources: build_sources(claim.chunk_indices, index_to_id)
          }
        ]
    end
  end

  defp build_sources(indices, index_to_id) do
    indices
    |> Enum.map(fn idx ->
      case Map.get(index_to_id, idx) do
        nil -> nil
        id -> %{chunk_id: id, score: 1.0}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
