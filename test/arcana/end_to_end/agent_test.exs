defmodule Arcana.EndToEnd.AgentTest do
  @moduledoc """
  End-to-end tests for Agent pipeline with real LLM APIs.

  Run with: `mix test --include end_to_end`
  Or just this file: `mix test test/arcana/end_to_end/agent_test.exs --include end_to_end`

  Requires ZAI_API_KEY environment variable.
  """
  use Arcana.LLMCase, async: false

  # LLM calls can be slow, especially when chaining multiple calls
  @moduletag timeout: :timer.minutes(5)

  alias Arcana.Agent

  setup do
    {:ok, _doc1} =
      Arcana.ingest(
        """
        Phoenix is a web framework for Elixir that implements the server-side
        Model-View-Controller (MVC) pattern. It provides high developer productivity
        and application performance through features like real-time communication.
        """,
        repo: Arcana.TestRepo,
        collection: "phoenix-docs"
      )

    {:ok, _doc2} =
      Arcana.ingest(
        """
        LiveView enables rich, real-time user experiences with server-rendered HTML.
        It works by maintaining a persistent WebSocket connection between client and
        server, allowing for interactive applications without writing JavaScript.
        """,
        repo: Arcana.TestRepo,
        collection: "phoenix-docs"
      )

    :ok
  end

  describe "basic pipeline" do
    @tag :end_to_end
    test "new -> search -> answer" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("What is Phoenix LiveView?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_binary(ctx.answer)
      assert String.length(ctx.answer) > 10
      refute Enum.empty?(ctx.results)
    end
  end

  describe "query preprocessing" do
    @tag :end_to_end
    test "pipeline with query expansion" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("real-time web apps", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand()
        |> Agent.search()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_binary(ctx.expanded_query)
      assert ctx.expanded_query != "real-time web apps"
      assert is_binary(ctx.answer)
    end

    @tag :end_to_end
    test "pipeline with query decomposition" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("Compare Phoenix MVC and LiveView approaches",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.decompose()
        |> Agent.search()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert [_ | _] = ctx.sub_questions
      assert is_binary(ctx.answer)
    end

    @tag :end_to_end
    test "pipeline with query rewriting" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("Hey, can you tell me about that Elixir web thing?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()
        |> Agent.search()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_binary(ctx.rewritten_query)
      # Rewritten query should be cleaner
      refute ctx.rewritten_query =~ "Hey"
      assert is_binary(ctx.answer)
    end
  end

  describe "result processing" do
    @tag :end_to_end
    test "pipeline with reranking" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("WebSocket connections", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search()
        |> Agent.rerank()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_map(ctx.rerank_scores)
      assert is_binary(ctx.answer)
    end

    @tag :end_to_end
    test "pipeline with collection selection" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("How does LiveView work?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["phoenix-docs", "unrelated-collection"])
        |> Agent.search()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_list(ctx.collections)
      assert "phoenix-docs" in ctx.collections
      assert is_binary(ctx.answer)
    end
  end

  describe "self-correction" do
    @tag :end_to_end
    test "pipeline with self-correcting search" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("Phoenix MVC pattern", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true, max_iterations: 2)
        |> Agent.answer()

      assert is_nil(ctx.error)
      refute Enum.empty?(ctx.results)

      [result | _] = ctx.results
      assert result.iterations >= 1
      assert is_binary(ctx.answer)
    end

    @tag :end_to_end
    test "pipeline with self-correcting answer" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("What is Phoenix?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search()
        |> Agent.answer(self_correct: true, max_corrections: 1)

      assert is_nil(ctx.error)
      assert is_binary(ctx.answer)
      assert ctx.correction_count >= 0
      assert is_list(ctx.corrections)
    end
  end

  describe "full agentic pipeline" do
    @tag :end_to_end
    test "complete pipeline with all features" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("Hey, what's the deal with real-time features in Phoenix?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()
        |> Agent.expand()
        |> Agent.search()
        |> Agent.rerank()
        |> Agent.answer()

      assert is_nil(ctx.error)
      assert is_binary(ctx.rewritten_query)
      assert is_binary(ctx.expanded_query)
      assert is_map(ctx.rerank_scores)
      assert is_binary(ctx.answer)
      assert String.length(ctx.answer) > 20
    end
  end

  describe "individual Agent steps" do
    @tag :end_to_end
    test "Agent.expand/2 expands query with synonyms" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("ML models", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand()

      assert is_nil(ctx.error)
      assert is_binary(ctx.expanded_query)
      assert ctx.expanded_query != "ML models"

      expanded_lower = String.downcase(ctx.expanded_query)
      assert expanded_lower =~ "ml" or expanded_lower =~ "machine" or expanded_lower =~ "learning"
    end

    @tag :end_to_end
    test "Agent.decompose/2 breaks complex question into sub-questions" do
      llm = llm_config(:zai)

      ctx =
        Agent.new(
          "What are the differences between Elixir and Erlang, and when should I use each?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.decompose()

      assert is_nil(ctx.error)
      assert is_list(ctx.sub_questions)
      # LLM should produce at least one sub-question
      refute Enum.empty?(ctx.sub_questions)
    end

    @tag :end_to_end
    test "Agent.rewrite/2 cleans up conversational queries" do
      llm = llm_config(:zai)

      ctx =
        Agent.new(
          "Hey, so I was wondering if you could help me understand how GenServer works?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()

      assert is_nil(ctx.error)
      assert is_binary(ctx.rewritten_query)
      refute ctx.rewritten_query =~ "Hey"
      refute ctx.rewritten_query =~ "wondering"
      assert ctx.rewritten_query =~ "GenServer"
    end

    @tag :end_to_end
    test "Agent.select/2 chooses relevant collections" do
      llm = llm_config(:zai)

      ctx =
        Agent.new("How do I write unit tests?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["testing-docs", "api-reference", "recipes"])

      assert is_nil(ctx.error)
      assert is_list(ctx.collections)
      refute Enum.empty?(ctx.collections)
      # Should prefer testing-docs for a testing question
      assert "testing-docs" in ctx.collections
    end
  end
end
