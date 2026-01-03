defmodule Arcana.Agent.ExpandTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

  describe "expand/2" do
    test "expands query with synonyms and related terms" do
      llm = fn prompt ->
        if prompt =~ "expand this query" do
          {:ok, "ML machine learning artificial intelligence models algorithms"}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("ML models", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand()

      assert ctx.expanded_query == "ML machine learning artificial intelligence models algorithms"
    end

    test "uses expanded_query in search when present" do
      {:ok, _doc} =
        Arcana.ingest("Machine learning and artificial intelligence are related fields.",
          repo: Arcana.TestRepo
        )

      llm = fn prompt ->
        if prompt =~ "expand this query" do
          {:ok, "machine learning artificial intelligence ML AI"}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("ML", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand()
        |> Agent.search()

      # The search should use the expanded query
      [result | _] = ctx.results
      assert result.question == "machine learning artificial intelligence ML AI"
    end

    test "handles LLM error gracefully" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx =
        Agent.new("ML models", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand()

      # On error, should keep original question and set expanded_query to nil
      assert is_nil(ctx.expanded_query)
      assert is_nil(ctx.error)
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error
      }

      result = Agent.expand(ctx)
      assert result.error == :previous_error
      assert is_nil(result.expanded_query)
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :expand, :start],
          [:arcana, :agent, :expand, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt ->
        {:ok, "expanded query terms"}
      end

      Agent.new("original query", repo: Arcana.TestRepo, llm: llm)
      |> Agent.expand()

      assert_receive {:telemetry, [:arcana, :agent, :expand, :start], _, start_meta}
      assert start_meta.question == "original query"

      assert_receive {:telemetry, [:arcana, :agent, :expand, :stop], _, stop_meta}
      assert stop_meta.expanded_query == "expanded query terms"

      :telemetry.detach(ref)
    end

    test "accepts custom prompt function" do
      llm = fn prompt ->
        assert prompt =~ "CUSTOM EXPAND PROMPT"
        {:ok, "custom expanded query"}
      end

      custom_prompt = fn question ->
        "CUSTOM EXPAND PROMPT: #{question}"
      end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand(prompt: custom_prompt)

      assert ctx.expanded_query == "custom expanded query"
    end

    test "accepts custom llm function" do
      context_llm = fn _prompt -> {:ok, "context llm response"} end
      override_llm = fn _prompt -> {:ok, "override llm response"} end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: context_llm)
        |> Agent.expand(llm: override_llm)

      assert ctx.expanded_query == "override llm response"
    end
  end

  describe "custom expander" do
    test "accepts custom expander module" do
      defmodule TestExpander do
        @behaviour Arcana.Agent.Expander

        @impl true
        def expand(question, _opts) do
          {:ok, question <> " programming development"}
        end
      end

      llm = fn _prompt -> raise "LLM should not be called" end

      ctx =
        Agent.new("Elixir", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand(expander: TestExpander)

      assert ctx.expanded_query == "Elixir programming development"
    end

    test "accepts custom expander function" do
      llm = fn _prompt -> raise "LLM should not be called" end

      custom_expander = fn question, _opts ->
        {:ok, question <> " synonyms related terms"}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.expand(expander: custom_expander)

      assert ctx.expanded_query == "test synonyms related terms"
    end
  end
end
