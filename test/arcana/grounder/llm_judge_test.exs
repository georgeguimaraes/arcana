defmodule Arcana.Grounder.LLMJudgeTest do
  use ExUnit.Case, async: true

  alias Arcana.Grounder.LLMJudge
  alias Arcana.Grounding.Result

  defp chunks do
    [
      %{id: 1, text: "Elixir was created by José Valim in 2011."},
      %{id: 2, text: "It runs on the Erlang virtual machine and emphasizes fault tolerance."}
    ]
  end

  defp judge_fn(claims) do
    fn _question, _answer, _chunks -> {:ok, %{claims: claims}} end
  end

  describe "ground/3" do
    test "computes score from supported vs total claims" do
      answer = "Elixir was created by José Valim in 2011. It runs on the BEAM."

      claims = [
        %{
          text: "Elixir was created by José Valim in 2011.",
          verdict: "supported",
          chunk_indices: [1]
        },
        %{text: "It runs on the BEAM.", verdict: "unsupported", chunk_indices: []}
      ]

      assert {:ok, %Result{score: 0.5} = result} =
               LLMJudge.ground(answer, chunks(),
                 question: "Who made Elixir?",
                 judge_fn: judge_fn(claims)
               )

      assert [%{text: "Elixir was created by José Valim in 2011.", sources: [%{chunk_id: 1}]}] =
               result.faithful_spans

      assert [%{text: "It runs on the BEAM.", sources: []}] = result.hallucinated_spans
    end

    test "maps claim text to byte offsets in the answer" do
      answer = "First sentence. Elixir runs on BEAM. Last bit."

      claims = [
        %{text: "Elixir runs on BEAM.", verdict: "contradicted", chunk_indices: [2]}
      ]

      assert {:ok, %Result{hallucinated_spans: [span]}} =
               LLMJudge.ground(answer, chunks(), question: "q", judge_fn: judge_fn(claims))

      assert span.start == 16
      assert span.end == 36
      assert binary_part(answer, span.start, span.end - span.start) == "Elixir runs on BEAM."
      assert span.sources == [%{chunk_id: 2, score: 1.0}]
    end

    test "skips claims whose text doesn't appear verbatim in the answer" do
      answer = "Elixir was made in 2011."

      claims = [
        %{text: "Elixir was made in 2011.", verdict: "supported", chunk_indices: [1]},
        %{text: "Paraphrased thing not in answer", verdict: "supported", chunk_indices: [1]}
      ]

      assert {:ok, %Result{score: 1.0} = result} =
               LLMJudge.ground(answer, chunks(), question: "q", judge_fn: judge_fn(claims))

      assert length(result.faithful_spans) == 1
    end

    test "treats contradicted claims as hallucinations" do
      answer = "Elixir was invented in 1995."

      claims = [
        %{text: "Elixir was invented in 1995.", verdict: "contradicted", chunk_indices: [1]}
      ]

      assert {:ok, %Result{score: +0.0} = result} =
               LLMJudge.ground(answer, chunks(), question: "q", judge_fn: judge_fn(claims))

      assert [%{text: "Elixir was invented in 1995.", sources: [%{chunk_id: 1}]}] =
               result.hallucinated_spans

      assert result.faithful_spans == []
    end

    test "empty answer short-circuits to perfect score" do
      assert {:ok, %Result{score: 1.0, hallucinated_spans: [], faithful_spans: []}} =
               LLMJudge.ground("", chunks(), question: "q", judge_fn: judge_fn([]))
    end

    test "empty chunks short-circuits to zero score" do
      assert {:ok, %Result{score: +0.0}} =
               LLMJudge.ground("anything", [], question: "q", judge_fn: judge_fn([]))
    end

    test "empty claims list returns perfect score" do
      assert {:ok, %Result{score: 1.0}} =
               LLMJudge.ground("any answer", chunks(), question: "q", judge_fn: judge_fn([]))
    end

    test "propagates errors from the judge function" do
      judge = fn _q, _a, _c -> {:error, :timeout} end

      assert {:error, :timeout} =
               LLMJudge.ground("answer", chunks(), question: "q", judge_fn: judge)
    end

    test "accepts string-keyed claim maps" do
      answer = "Elixir runs on BEAM."

      claims = [
        %{"text" => "Elixir runs on BEAM.", "verdict" => "supported", "chunk_indices" => [2]}
      ]

      assert {:ok, %Result{score: 1.0, faithful_spans: [span]}} =
               LLMJudge.ground(answer, chunks(), question: "q", judge_fn: judge_fn(claims))

      assert span.sources == [%{chunk_id: 2, score: 1.0}]
    end

    test "drops out-of-range chunk indices from sources" do
      answer = "Elixir runs on BEAM."

      claims = [
        %{text: "Elixir runs on BEAM.", verdict: "supported", chunk_indices: [99]}
      ]

      assert {:ok, %Result{faithful_spans: [span]}} =
               LLMJudge.ground(answer, chunks(), question: "q", judge_fn: judge_fn(claims))

      assert span.sources == []
    end
  end

  describe "parse_judge_json/1" do
    test "parses a clean JSON object" do
      text = ~s({"claims": [{"text": "foo", "verdict": "supported", "chunk_indices": [1]}]})

      assert {:ok, %{claims: [claim]}} = LLMJudge.parse_judge_json(text)
      assert claim["text"] == "foo"
      assert claim["verdict"] == "supported"
      assert claim["chunk_indices"] == [1]
    end

    test "extracts JSON from prose wrapping" do
      text = """
      Here is the evaluation:

      {"claims": [{"text": "bar", "verdict": "unsupported", "chunk_indices": []}]}

      Hope that helps!
      """

      assert {:ok, %{claims: [claim]}} = LLMJudge.parse_judge_json(text)
      assert claim["text"] == "bar"
    end

    test "extracts JSON from markdown code fences" do
      text = """
      ```json
      {"claims": [{"text": "baz", "verdict": "contradicted", "chunk_indices": [2]}]}
      ```
      """

      assert {:ok, %{claims: [claim]}} = LLMJudge.parse_judge_json(text)
      assert claim["verdict"] == "contradicted"
    end

    test "handles nested objects inside claims" do
      text = ~s({"claims": [{"text": "x", "verdict": "supported", "meta": {"nested": 1}}]})

      assert {:ok, %{claims: [claim]}} = LLMJudge.parse_judge_json(text)
      assert claim["meta"] == %{"nested" => 1}
    end

    test "handles braces inside JSON string values" do
      text = ~s({"claims": [{"text": "has {brace} inside", "verdict": "supported"}]})

      assert {:ok, %{claims: [claim]}} = LLMJudge.parse_judge_json(text)
      assert claim["text"] == "has {brace} inside"
    end

    test "returns error on unparseable text" do
      assert {:error, :invalid_judge_response} = LLMJudge.parse_judge_json("not json at all")
    end

    test "returns error when no top-level object is present" do
      assert {:error, :invalid_judge_response} = LLMJudge.parse_judge_json("[1, 2, 3]")
    end

    test "returns empty claims when key is missing" do
      assert {:ok, %{claims: []}} = LLMJudge.parse_judge_json(~s({"other": "stuff"}))
    end
  end
end
