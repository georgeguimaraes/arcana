defmodule Arcana.RerankerTest do
  use ExUnit.Case, async: true

  alias Arcana.Agent.Reranker.LLM

  describe "Agent.Reranker.LLM.rerank/3" do
    test "scores and filters chunks by threshold" do
      chunks = [
        %{id: "1", text: "Elixir is a functional language"},
        %{id: "2", text: "Weather is nice today"},
        %{id: "3", text: "Elixir runs on the BEAM VM"}
      ]

      # LLM returns high scores for relevant chunks, low for irrelevant
      llm = fn prompt ->
        cond do
          prompt =~ "functional language" ->
            {:ok, ~s({"score": 9, "reasoning": "directly relevant"})}

          prompt =~ "Weather" ->
            {:ok, ~s({"score": 2, "reasoning": "not relevant"})}

          prompt =~ "BEAM VM" ->
            {:ok, ~s({"score": 8, "reasoning": "relevant context"})}
        end
      end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      # Should filter out the weather chunk (score 2)
      assert length(result) == 2
      # Should be sorted by score descending
      assert Enum.at(result, 0).id == "1"
      assert Enum.at(result, 1).id == "3"
    end

    test "returns all chunks when all pass threshold" do
      chunks = [
        %{id: "1", text: "Elixir is great"},
        %{id: "2", text: "Elixir is functional"}
      ]

      llm = fn _prompt -> {:ok, ~s({"score": 8, "reasoning": "relevant"})} end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      assert length(result) == 2
    end

    test "returns empty list when no chunks pass threshold" do
      chunks = [
        %{id: "1", text: "Unrelated content"}
      ]

      llm = fn _prompt -> {:ok, ~s({"score": 3, "reasoning": "not relevant"})} end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      assert result == []
    end

    test "uses default threshold of 7 when not specified" do
      chunks = [
        %{id: "1", text: "Score 6 content"},
        %{id: "2", text: "Score 8 content"}
      ]

      llm = fn prompt ->
        if prompt =~ "Score 6" do
          {:ok, ~s({"score": 6, "reasoning": "below default"})}
        else
          {:ok, ~s({"score": 8, "reasoning": "above default"})}
        end
      end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "2"
    end

    test "handles LLM error for individual chunk gracefully" do
      chunks = [
        %{id: "1", text: "Good chunk"},
        %{id: "2", text: "Error chunk"},
        %{id: "3", text: "Another good chunk"}
      ]

      llm = fn prompt ->
        if prompt =~ "Error chunk" do
          {:error, :llm_failed}
        else
          {:ok, ~s({"score": 9, "reasoning": "good"})}
        end
      end

      # Should still succeed, just filter out the error chunk
      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 2
      refute Enum.any?(result, &(&1.id == "2"))
    end

    test "handles malformed JSON response" do
      chunks = [%{id: "1", text: "Some content"}]

      llm = fn _prompt -> {:ok, "not valid json"} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      # Malformed response = score 0, filtered out
      assert result == []
    end

    test "accepts custom prompt function" do
      chunks = [%{id: "1", text: "Content"}]

      custom_prompt = fn question, chunk_text ->
        "Custom: #{question} - #{chunk_text}"
      end

      llm = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, ~s({"score": 9, "reasoning": "ok"})}
      end

      {:ok, _result} = LLM.rerank("Q?", chunks, llm: llm, prompt: custom_prompt)

      assert_receive {:prompt, prompt}
      assert prompt == "Custom: Q? - Content"
    end

    test "returns empty list for empty input" do
      llm = fn _prompt -> {:ok, ~s({"score": 9})} end

      {:ok, result} = LLM.rerank("question", [], llm: llm)

      assert result == []
    end
  end
end
