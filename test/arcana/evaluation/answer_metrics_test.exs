defmodule Arcana.Evaluation.AnswerMetricsTest do
  use ExUnit.Case, async: true

  alias Arcana.Evaluation.AnswerMetrics

  describe "evaluate_faithfulness/4" do
    test "returns score and reasoning for faithful answer" do
      chunks = [
        %{text: "Elixir is a functional programming language that runs on the BEAM VM."},
        %{text: "Elixir was created by José Valim in 2011."}
      ]

      question = "What is Elixir?"
      answer = "Elixir is a functional programming language that runs on the BEAM VM."

      llm = fn _prompt ->
        {:ok, ~s({"score": 9, "reasoning": "Answer directly quotes the context."})}
      end

      {:ok, result} = AnswerMetrics.evaluate_faithfulness(question, chunks, answer, llm: llm)

      assert result.score == 9
      assert result.reasoning == "Answer directly quotes the context."
    end

    test "returns low score for hallucinated answer" do
      chunks = [
        %{text: "Elixir is a functional programming language."}
      ]

      question = "What is Elixir?"
      answer = "Elixir was created by Guido van Rossum and is used for machine learning."

      llm = fn _prompt ->
        {:ok,
         ~s({"score": 2, "reasoning": "Answer contains hallucinated information not in context."})}
      end

      {:ok, result} = AnswerMetrics.evaluate_faithfulness(question, chunks, answer, llm: llm)

      assert result.score == 2
      assert result.reasoning =~ "hallucinated"
    end

    test "handles LLM error gracefully" do
      llm = fn _prompt -> {:error, :api_error} end

      result = AnswerMetrics.evaluate_faithfulness("Q?", [%{text: "..."}], "A", llm: llm)

      assert {:error, :api_error} = result
    end

    test "handles malformed JSON response" do
      llm = fn _prompt -> {:ok, "not valid json"} end

      result = AnswerMetrics.evaluate_faithfulness("Q?", [%{text: "..."}], "A", llm: llm)

      assert {:error, :invalid_response} = result
    end

    test "handles JSON without required fields" do
      llm = fn _prompt -> {:ok, ~s({"score": 5})} end

      {:ok, result} = AnswerMetrics.evaluate_faithfulness("Q?", [%{text: "..."}], "A", llm: llm)

      assert result.score == 5
      assert result.reasoning == nil
    end

    test "clamps score to 0-10 range" do
      llm = fn _prompt -> {:ok, ~s({"score": 15, "reasoning": "test"})} end

      {:ok, result} = AnswerMetrics.evaluate_faithfulness("Q?", [%{text: "..."}], "A", llm: llm)

      assert result.score == 10
    end

    test "accepts custom prompt function" do
      custom_prompt = fn question, _chunks, _answer ->
        "Custom prompt for: #{question}"
      end

      llm = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, ~s({"score": 8, "reasoning": "ok"})}
      end

      {:ok, _result} =
        AnswerMetrics.evaluate_faithfulness("Q?", [%{text: "..."}], "A",
          llm: llm,
          prompt: custom_prompt
        )

      assert_receive {:prompt, "Custom prompt for: Q?"}
    end
  end

  describe "default_prompt/0" do
    test "returns the default faithfulness prompt template" do
      prompt = AnswerMetrics.default_prompt()

      assert prompt =~ "{question}"
      assert prompt =~ "{chunks}"
      assert prompt =~ "{answer}"
      assert prompt =~ "faithfulness"
    end
  end
end
