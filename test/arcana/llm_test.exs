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

  describe "{module, function} tuples" do
    defmodule FakeLLM do
      def complete(prompt, context, _opts), do: {:ok, "mfa3: #{prompt} (#{length(context)})"}
      def complete_two(prompt, _context), do: {:ok, "mfa2: #{prompt}"}
      def rewrite(prompt), do: {:ok, "mfa1: #{prompt}"}
    end

    test "dispatches to the highest supported arity" do
      context = [%{text: "chunk1"}]

      assert {:ok, "mfa3: q (1)"} = LLM.complete({FakeLLM, :complete}, "q", context, [])
      assert {:ok, "mfa2: q"} = LLM.complete({FakeLLM, :complete_two}, "q", context, [])
      assert {:ok, "mfa1: q"} = LLM.complete({FakeLLM, :rewrite}, "q", context, [])
    end

    test "returns an error for a function that doesn't exist" do
      assert {:error, {:invalid_llm_mfa, {FakeLLM, :nope}}} =
               LLM.complete({FakeLLM, :nope}, "q", [], [])
    end

    test "distinguishes a module that doesn't exist from a wrong arity" do
      assert {:error, {:llm_module_not_found, NoSuch.Module}} =
               LLM.complete({NoSuch.Module, :complete}, "q", [], [])
    end

    test "model string with opts still dispatches through the tuple impl" do
      assert LLM.impl_for({"openai:gpt-4o-mini", api_key: "k"}) == Arcana.LLM.Tuple
    end
  end

  describe "Req.LLM integration" do
    test "works with OpenAI model string" do
      # We can't actually call the API, but we can verify the string is accepted
      model = "openai:gpt-4o-mini"

      # The protocol should be implemented for BitString
      assert LLM.impl_for(model) == Arcana.LLM.BitString
    end

    test "works with Anthropic model string" do
      model = "anthropic:claude-sonnet-4-20250514"

      assert LLM.impl_for(model) == Arcana.LLM.BitString
    end
  end
end
