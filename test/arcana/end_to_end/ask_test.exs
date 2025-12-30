defmodule Arcana.EndToEnd.AskTest do
  @moduledoc """
  End-to-end tests for Arcana.ask/2 with real LLM APIs.

  Run with: `mix test --include end_to_end`
  Or just this file: `mix test test/arcana/end_to_end/ask_test.exs --include end_to_end`

  Requires ZAI_API_KEY environment variable.
  """
  use Arcana.LLMCase, async: false

  # LLM calls can be slow
  @moduletag timeout: :timer.minutes(2)

  describe "Arcana.ask/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest(
          """
          Elixir is a dynamic, functional programming language designed for building
          scalable and maintainable applications. It runs on the Erlang VM (BEAM),
          known for running low-latency, distributed, and fault-tolerant systems.
          """,
          repo: Arcana.TestRepo
        )

      :ok
    end

    @tag :end_to_end
    test "answers question using retrieved context" do
      llm = llm_config(:zai)

      {:ok, answer, results} =
        Arcana.ask("What is Elixir?", repo: Arcana.TestRepo, llm: llm)

      assert is_binary(answer)
      assert String.length(answer) > 10
      assert is_list(results)
      refute Enum.empty?(results)

      # Answer should mention something relevant
      answer_lower = String.downcase(answer)

      assert answer_lower =~ "elixir" or answer_lower =~ "programming" or
               answer_lower =~ "language"
    end

    @tag :end_to_end
    test "returns search results alongside answer" do
      llm = llm_config(:zai)

      {:ok, _answer, results} =
        Arcana.ask("Tell me about BEAM", repo: Arcana.TestRepo, llm: llm)

      assert is_list(results)
      refute Enum.empty?(results)

      first = hd(results)
      assert Map.has_key?(first, :text)
      assert Map.has_key?(first, :score)
      assert Map.has_key?(first, :document_id)
    end

    @tag :end_to_end
    test "handles question with no relevant context gracefully" do
      llm = llm_config(:zai)

      {:ok, answer, _results} =
        Arcana.ask("What is the capital of France?", repo: Arcana.TestRepo, llm: llm)

      # Should still return an answer (likely saying it doesn't know)
      assert is_binary(answer)
    end

    @tag :end_to_end
    test "respects limit option" do
      llm = llm_config(:zai)

      {:ok, _answer, results} =
        Arcana.ask("Elixir", repo: Arcana.TestRepo, llm: llm, limit: 1)

      assert length(results) <= 1
    end
  end
end
