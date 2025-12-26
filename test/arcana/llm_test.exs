defmodule Arcana.LLMTest do
  use ExUnit.Case, async: true

  alias Arcana.LLM

  describe "Arcana.LLM protocol" do
    test "works with anonymous functions (arity 2)" do
      llm = fn prompt, context ->
        {:ok, "Answer to: #{prompt} with #{length(context)} chunks"}
      end

      context = [%{text: "chunk1"}, %{text: "chunk2"}]
      {:ok, result} = LLM.complete(llm, "test question", context)

      assert result == "Answer to: test question with 2 chunks"
    end

    test "works with anonymous functions (arity 1) for rewriters" do
      llm = fn prompt ->
        {:ok, "Expanded: #{prompt}"}
      end

      {:ok, result} = LLM.complete(llm, "short query", [])

      assert result == "Expanded: short query"
    end

    test "passes through errors from functions" do
      llm = fn _prompt, _context ->
        {:error, :api_error}
      end

      assert {:error, :api_error} = LLM.complete(llm, "test", [])
    end
  end

  describe "LangChain integration" do
    test "works with ChatOpenAI struct" do
      # We can't actually call the API, but we can verify the struct is accepted
      chat = %LangChain.ChatModels.ChatOpenAI{
        model: "gpt-4o-mini",
        temperature: 0.7
      }

      # The protocol should be implemented for this struct
      assert LLM.impl_for(chat) != nil
    end

    test "works with ChatAnthropic struct" do
      chat = %LangChain.ChatModels.ChatAnthropic{
        model: "claude-3-5-sonnet-latest"
      }

      assert LLM.impl_for(chat) != nil
    end
  end
end
