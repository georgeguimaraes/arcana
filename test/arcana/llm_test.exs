defmodule Arcana.LLMTest do
  use ExUnit.Case, async: true

  alias Arcana.LLM

  describe "Arcana.LLM protocol" do
    test "works with anonymous functions (arity 2)" do
      llm = fn prompt, context ->
        {:ok, "Answer to: #{prompt} with #{length(context)} chunks"}
      end

      context = [%{text: "chunk1"}, %{text: "chunk2"}]
      {:ok, result} = LLM.complete(llm, "test question", context, [])

      assert result == "Answer to: test question with 2 chunks"
    end

    test "works with anonymous functions (arity 1) for rewriters" do
      llm = fn prompt ->
        {:ok, "Expanded: #{prompt}"}
      end

      {:ok, result} = LLM.complete(llm, "short query", [], [])

      assert result == "Expanded: short query"
    end

    test "passes through errors from functions" do
      llm = fn _prompt, _context ->
        {:error, :api_error}
      end

      assert {:error, :api_error} = LLM.complete(llm, "test", [], [])
    end
  end

  describe "Req.LLM integration" do
    test "works with OpenAI model string" do
      # We can't actually call the API, but we can verify the string is accepted
      model = "openai:gpt-4o-mini"

      # The protocol should be implemented for BitString
      assert LLM.impl_for(model) != nil
    end

    test "works with Anthropic model string" do
      model = "anthropic:claude-sonnet-4-20250514"

      assert LLM.impl_for(model) != nil
    end
  end
end
