defmodule Arcana.RerankerTest do
  use ExUnit.Case, async: true

  alias Arcana.Pipeline.Reranker.LLM

  describe "Pipeline.Reranker.LLM.rerank/3" do
    test "scores and filters chunks by threshold" do
      chunks = [
        %{id: "1", text: "Elixir is a functional language"},
        %{id: "2", text: "Weather is nice today"},
        %{id: "3", text: "Elixir runs on the BEAM VM"}
      ]

      llm = fn _prompt ->
        {:ok, ~s({"1": 9, "2": 2, "3": 8})}
      end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      assert length(result) == 2
      assert Enum.at(result, 0).id == "1"
      assert Enum.at(result, 1).id == "3"
    end

    test "returns all chunks when all pass threshold" do
      chunks = [
        %{id: "1", text: "Elixir is great"},
        %{id: "2", text: "Elixir is functional"}
      ]

      llm = fn _prompt -> {:ok, ~s({"1": 8, "2": 9})} end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      assert length(result) == 2
      # Sorted by score descending
      assert Enum.at(result, 0).id == "2"
      assert Enum.at(result, 1).id == "1"
    end

    test "returns empty list when no chunks pass threshold" do
      chunks = [
        %{id: "1", text: "Unrelated content"}
      ]

      llm = fn _prompt -> {:ok, ~s({"1": 3})} end

      {:ok, result} = LLM.rerank("What is Elixir?", chunks, llm: llm, threshold: 7)

      assert result == []
    end

    test "omitted passage IDs default to score 0" do
      chunks = [
        %{id: "1", text: "Relevant content"},
        %{id: "2", text: "Irrelevant content"}
      ]

      # LLM omits low-scoring passages per prompt instruction
      llm = fn _prompt -> {:ok, ~s({"1": 9})} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "1"
    end

    test "uses default threshold of 7 when not specified" do
      chunks = [
        %{id: "1", text: "Score 6 content"},
        %{id: "2", text: "Score 8 content"}
      ]

      llm = fn _prompt -> {:ok, ~s({"1": 6, "2": 8})} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "2"
    end

    test "handles LLM error gracefully by returning all chunks" do
      chunks = [
        %{id: "1", text: "Good chunk"},
        %{id: "2", text: "Another chunk"}
      ]

      llm = fn _prompt -> {:error, :llm_failed} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 2
      assert Enum.at(result, 0).id == "1"
      assert Enum.at(result, 1).id == "2"
    end

    test "handles malformed JSON by returning all chunks" do
      chunks = [%{id: "1", text: "Some content"}]

      llm = fn _prompt -> {:ok, "not valid json"} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "1"
    end

    test "handles markdown code fences in response" do
      chunks = [
        %{id: "1", text: "Relevant"},
        %{id: "2", text: "Irrelevant"}
      ]

      llm = fn _prompt -> {:ok, "```json\n{\"1\": 9, \"2\": 3}\n```"} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "1"
    end

    test "handles preamble text before JSON" do
      chunks = [
        %{id: "1", text: "Relevant"},
        %{id: "2", text: "Irrelevant"}
      ]

      llm = fn _prompt -> {:ok, "Here are the scores:\n{\"1\": 9, \"2\": 3}"} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 1
      assert Enum.at(result, 0).id == "1"
    end

    test "handles JSON array instead of object by returning all chunks" do
      chunks = [%{id: "1", text: "Some content"}]

      llm = fn _prompt -> {:ok, "[1, 2, 3]"} end

      {:ok, result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert length(result) == 1
    end

    test "accepts custom prompt function" do
      chunks = [%{id: "1", text: "Content"}]

      custom_prompt = fn question, passages ->
        passage_text =
          Enum.map_join(passages, "\n", fn {id, chunk} -> "#{id}: #{chunk.text}" end)

        "Custom: #{question}\n#{passage_text}"
      end

      llm = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, ~s({"1": 9})}
      end

      {:ok, _result} = LLM.rerank("Q?", chunks, llm: llm, prompt: custom_prompt)

      assert_receive {:prompt, prompt}
      assert prompt == "Custom: Q?\n1: Content"
    end

    test "returns empty list for empty input" do
      llm = fn _prompt -> {:ok, ~s({"1": 9})} end

      {:ok, result} = LLM.rerank("question", [], llm: llm)

      assert result == []
    end

    test "makes exactly one LLM call for multiple chunks" do
      chunks = [
        %{id: "1", text: "First"},
        %{id: "2", text: "Second"},
        %{id: "3", text: "Third"}
      ]

      llm = fn _prompt ->
        send(self(), :llm_called)
        {:ok, ~s({"1": 8, "2": 9, "3": 7})}
      end

      {:ok, _result} = LLM.rerank("question", chunks, llm: llm, threshold: 7)

      assert_receive :llm_called
      refute_receive :llm_called
    end

    test "prompt contains all passages with bracket IDs" do
      chunks = [
        %{id: "a", text: "First passage"},
        %{id: "b", text: "Second passage"}
      ]

      llm = fn prompt ->
        send(self(), {:prompt, prompt})
        {:ok, ~s({"1": 8, "2": 9})}
      end

      {:ok, _result} = LLM.rerank("my question", chunks, llm: llm, threshold: 7)

      assert_receive {:prompt, prompt}
      assert prompt =~ "[1] First passage"
      assert prompt =~ "[2] Second passage"
      assert prompt =~ "my question"
    end
  end
end
