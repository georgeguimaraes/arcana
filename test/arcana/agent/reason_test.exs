defmodule Arcana.Agent.ReasonTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

  describe "reason/2" do
    test "accepts results when LLM says sufficient" do
      llm = fn prompt ->
        assert prompt =~ "What is Elixir"
        {:ok, ~s({"sufficient": true, "reasoning": "Results contain relevant info"})}
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [%{id: "1", text: "Elixir is functional", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["What is Elixir?"])
      }

      ctx = Agent.reason(ctx)

      # Should not add more queries
      assert MapSet.size(ctx.queries_tried) == 1
      assert ctx.reason_iterations == 0
    end

    test "searches again when LLM says insufficient" do
      call_count = :counters.new(1, [:atomics])

      llm = fn prompt ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          count == 0 and prompt =~ "sufficient" ->
            {:ok, ~s({"sufficient": false, "missing": "concurrency model", "follow_up_query": "Elixir concurrency actors"})}

          count == 1 and prompt =~ "sufficient" ->
            {:ok, ~s({"sufficient": true, "reasoning": "Now has concurrency info"})}

          true ->
            {:ok, "response"}
        end
      end

      # Ingest some test content
      {:ok, _} =
        Arcana.ingest("Elixir uses actors for concurrency.",
          repo: Arcana.TestRepo,
          collection: "reason-test"
        )

      ctx = %Context{
        question: "How does Elixir handle concurrency?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "How does Elixir handle concurrency?",
            collection: "reason-test",
            chunks: [%{id: "1", text: "Elixir is functional", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["How does Elixir handle concurrency?"])
      }

      ctx = Agent.reason(ctx)

      # Should have searched again
      assert ctx.reason_iterations == 1
      assert MapSet.member?(ctx.queries_tried, "Elixir concurrency actors")
    end

    test "respects max_iterations limit" do
      llm = fn prompt ->
        if prompt =~ "sufficient" do
          {:ok, ~s({"sufficient": false, "missing": "more info", "follow_up_query": "query #{:rand.uniform(1000)}"})}
        else
          {:ok, "response"}
        end
      end

      {:ok, _} =
        Arcana.ingest("Some content for max iterations test.",
          repo: Arcana.TestRepo,
          collection: "max-iter-test"
        )

      ctx = %Context{
        question: "test question",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "test",
            collection: "max-iter-test",
            chunks: [%{id: "1", text: "content", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["test question"])
      }

      ctx = Agent.reason(ctx, max_iterations: 2)

      # Should stop after 2 iterations even if still insufficient
      assert ctx.reason_iterations == 2
    end

    test "prevents duplicate queries" do
      llm = fn prompt ->
        if prompt =~ "sufficient" do
          # Always suggest the same follow-up query
          {:ok, ~s({"sufficient": false, "missing": "more", "follow_up_query": "same query"})}
        else
          {:ok, "response"}
        end
      end

      {:ok, _} =
        Arcana.ingest("Content for duplicate test.",
          repo: Arcana.TestRepo,
          collection: "dup-test"
        )

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "dup-test", chunks: [%{id: "1", text: "x", score: 0.9}]}
        ],
        queries_tried: MapSet.new(["test", "same query"])
      }

      ctx = Agent.reason(ctx, max_iterations: 3)

      # Should stop because follow_up_query was already tried
      assert ctx.reason_iterations == 0
    end

    test "defaults to accepting on LLM error" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "default", chunks: []}
        ],
        queries_tried: MapSet.new(["test"])
      }

      ctx = Agent.reason(ctx)

      # Should proceed without error
      assert is_nil(ctx.error)
      assert ctx.reason_iterations == 0
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :reason, :start],
          [:arcana, :agent, :reason, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, ~s({"sufficient": true, "reasoning": "ok"})} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "default", chunks: []}
        ],
        queries_tried: MapSet.new(["test"])
      }

      Agent.reason(ctx)

      assert_receive {:telemetry, [:arcana, :agent, :reason, :start], _, %{question: "test"}}
      assert_receive {:telemetry, [:arcana, :agent, :reason, :stop], _, %{iterations: 0}}

      :telemetry.detach(ref)
    end

    test "initializes queries_tried if not set" do
      llm = fn _prompt -> {:ok, ~s({"sufficient": true})} end

      ctx = %Context{
        question: "my question",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [%{question: "test", collection: "default", chunks: []}],
        queries_tried: nil
      }

      ctx = Agent.reason(ctx)

      assert MapSet.member?(ctx.queries_tried, "my question")
    end
  end
end
