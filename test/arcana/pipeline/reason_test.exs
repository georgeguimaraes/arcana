defmodule Arcana.Pipeline.ReasonTest do
  use Arcana.DataCase, async: true

  alias Arcana.Pipeline
  alias Arcana.Pipeline.Context

  # Asks for one follow-up search, then accepts. Anything that isn't the
  # sufficiency prompt gets a throwaway answer.
  defp insufficient_then_sufficient_llm do
    call_count = :counters.new(1, [:atomics])

    fn prompt ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      cond do
        count == 0 and prompt =~ "sufficient" ->
          {:ok,
           ~s({"sufficient": false, "missing": "concurrency model", "follow_up_query": "Elixir concurrency actors"})}

        prompt =~ "sufficient" ->
          {:ok, ~s({"sufficient": true, "reasoning": "Now has concurrency info"})}

        true ->
          {:ok, "response"}
      end
    end
  end

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

      ctx = Pipeline.reason(ctx)

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
            {:ok,
             ~s({"sufficient": false, "missing": "concurrency model", "follow_up_query": "Elixir concurrency actors"})}

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

      ctx = Pipeline.reason(ctx)

      # Should have searched again
      assert ctx.reason_iterations == 1
      assert MapSet.member?(ctx.queries_tried, "Elixir concurrency actors")
    end

    test "respects max_iterations limit" do
      llm = fn prompt ->
        if prompt =~ "sufficient" do
          {:ok,
           ~s({"sufficient": false, "missing": "more info", "follow_up_query": "query #{System.unique_integer([:positive])}"})}
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

      ctx = Pipeline.reason(ctx, max_iterations: 2)

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

      ctx = Pipeline.reason(ctx, max_iterations: 3)

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

      ctx = Pipeline.reason(ctx)

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
          [:arcana, :pipeline, :reason, :start],
          [:arcana, :pipeline, :reason, :stop]
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

      Pipeline.reason(ctx)

      assert_receive {:telemetry, [:arcana, :pipeline, :reason, :start], _, %{question: "test"}}
      assert_receive {:telemetry, [:arcana, :pipeline, :reason, :stop], _, %{iterations: 0}}

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

      ctx = Pipeline.reason(ctx)

      assert MapSet.member?(ctx.queries_tried, "my question")
    end

    # A caller that scopes retrieval by handing search/2 a tenant searcher
    # would silently get the default (unscoped) searcher back for the
    # follow-up searches if reason/2 didn't inherit it, which hands the
    # caller chunks from outside the tenant.
    test "inherits the searcher from search/2 without repeating the option" do
      test_pid = self()

      searcher = fn question, _collection, _opts ->
        send(test_pid, {:searched, question})
        {:ok, [%{id: "1", text: "scoped chunk", score: 0.9}]}
      end

      ctx =
        "How does Elixir handle concurrency?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: insufficient_then_sufficient_llm())
        |> Pipeline.search(searcher: searcher, collection: "inherit-searcher-test")
        |> Pipeline.reason()

      assert ctx.reason_iterations == 1
      assert_received {:searched, "How does Elixir handle concurrency?"}
      assert_received {:searched, "Elixir concurrency actors"}
    end

    test "an explicit searcher on reason/2 beats the inherited one" do
      test_pid = self()

      search_searcher = fn _question, _collection, _opts ->
        {:ok, [%{id: "1", text: "from search", score: 0.9}]}
      end

      reason_searcher = fn question, _collection, _opts ->
        send(test_pid, {:reason_searched, question})
        {:ok, [%{id: "2", text: "from reason", score: 0.9}]}
      end

      ctx =
        "How does Elixir handle concurrency?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: insufficient_then_sufficient_llm())
        |> Pipeline.search(searcher: search_searcher, collection: "explicit-searcher-test")
        |> Pipeline.reason(searcher: reason_searcher)

      assert ctx.reason_iterations == 1
      assert_received {:reason_searched, "Elixir concurrency actors"}
    end

    test "skips reasoning when skip_retrieval is true" do
      # LLM should not be called since we're skipping retrieval
      llm = fn _prompt -> raise "LLM should not be called" end

      ctx = %Context{
        question: "What is 2 + 2?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        skip_retrieval: true,
        results: [],
        queries_tried: nil
      }

      ctx = Pipeline.reason(ctx)

      # Should not have done any reasoning
      assert ctx.reason_iterations == 0 or is_nil(ctx.reason_iterations)
    end
  end
end
