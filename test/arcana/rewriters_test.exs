defmodule Arcana.RewritersTest do
  use ExUnit.Case, async: true

  alias Arcana.Rewriters

  describe "expand/2" do
    test "calls LLM with expansion prompt and query" do
      test_pid = self()

      llm = fn prompt ->
        send(test_pid, {:llm_called, prompt})
        {:ok, "expanded query with synonyms"}
      end

      {:ok, result} = Rewriters.expand("ML models", llm: llm)

      assert_receive {:llm_called, prompt}
      assert prompt =~ "ML models"
      assert prompt =~ "synonym" or prompt =~ "expand" or prompt =~ "related"
      assert result == "expanded query with synonyms"
    end

    test "accepts custom prompt template" do
      test_pid = self()

      llm = fn prompt ->
        send(test_pid, {:llm_called, prompt})
        {:ok, "custom result"}
      end

      {:ok, _} =
        Rewriters.expand("test query",
          llm: llm,
          prompt: "My custom prompt: {query}"
        )

      assert_receive {:llm_called, prompt}
      assert prompt == "My custom prompt: test query"
    end

    test "returns error when LLM fails" do
      llm = fn _prompt -> {:error, :api_error} end

      assert {:error, :api_error} = Rewriters.expand("test", llm: llm)
    end

    test "returns rewriter function when no query given" do
      llm = fn _prompt -> {:ok, "result"} end

      rewriter = Rewriters.expand(llm: llm)

      assert is_function(rewriter, 1)
      assert {:ok, "result"} = rewriter.("any query")
    end
  end

  describe "keywords/2" do
    test "calls LLM with keyword extraction prompt" do
      test_pid = self()

      llm = fn prompt ->
        send(test_pid, {:llm_called, prompt})
        {:ok, "machine learning models neural"}
      end

      {:ok, result} = Rewriters.keywords("What are the best ML models for NLP?", llm: llm)

      assert_receive {:llm_called, prompt}
      assert prompt =~ "ML models"
      assert prompt =~ "keyword" or prompt =~ "extract" or prompt =~ "key term"
      assert result == "machine learning models neural"
    end

    test "returns rewriter function when no query given" do
      llm = fn _prompt -> {:ok, "keywords"} end

      rewriter = Rewriters.keywords(llm: llm)

      assert is_function(rewriter, 1)
    end
  end

  describe "decompose/2" do
    test "calls LLM with decomposition prompt" do
      test_pid = self()

      llm = fn prompt ->
        send(test_pid, {:llm_called, prompt})
        {:ok, "sub-query 1\nsub-query 2"}
      end

      {:ok, result} = Rewriters.decompose("Complex multi-part question?", llm: llm)

      assert_receive {:llm_called, prompt}
      assert prompt =~ "Complex multi-part question?"
      assert prompt =~ "break" or prompt =~ "decompose" or prompt =~ "sub"
      assert result == "sub-query 1\nsub-query 2"
    end

    test "returns rewriter function when no query given" do
      llm = fn _prompt -> {:ok, "decomposed"} end

      rewriter = Rewriters.decompose(llm: llm)

      assert is_function(rewriter, 1)
    end
  end

  describe "integration with search" do
    test "expand/1 returns function compatible with search rewriter option" do
      llm = fn _prompt -> {:ok, "expanded query"} end

      rewriter = Rewriters.expand(llm: llm)

      # Should match the rewriter signature: fn(query) -> {:ok, rewritten}
      assert {:ok, "expanded query"} = rewriter.("original query")
    end
  end

  describe "protocol support" do
    test "accepts any type implementing Arcana.LLM protocol" do
      # Arity-2 functions also work (context is passed as empty list)
      llm = fn prompt, _context ->
        {:ok, "expanded: #{prompt}"}
      end

      {:ok, result} = Rewriters.expand("test query", llm: llm)

      assert result =~ "test query"
    end

    test "model strings are accepted (requires req_llm)" do
      # Verify the protocol is implemented for model strings
      model = "openai:gpt-4o-mini"

      assert Arcana.LLM.impl_for(model) != nil
    end
  end
end
