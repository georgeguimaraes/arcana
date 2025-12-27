defmodule Arcana.AgentTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

  describe "new/2" do
    test "creates context with required options" do
      ctx = Agent.new("What is Elixir?", repo: Arcana.TestRepo, llm: &mock_llm/1)

      assert %Context{} = ctx
      assert ctx.question == "What is Elixir?"
      assert ctx.repo == Arcana.TestRepo
      assert is_function(ctx.llm, 1)
    end

    test "sets default limit and threshold" do
      ctx = Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)

      assert ctx.limit == 5
      assert ctx.threshold == 0.5
    end

    test "allows overriding limit and threshold" do
      ctx =
        Agent.new("test",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 10,
          threshold: 0.7
        )

      assert ctx.limit == 10
      assert ctx.threshold == 0.7
    end

    test "raises without repo" do
      assert_raise KeyError, fn ->
        Agent.new("test", llm: &mock_llm/1)
      end
    end

    test "raises without llm" do
      assert_raise KeyError, fn ->
        Agent.new("test", repo: Arcana.TestRepo)
      end
    end
  end

  describe "search/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language.",
          repo: Arcana.TestRepo
        )

      :ok
    end

    test "searches and populates results" do
      ctx =
        Agent.new("functional programming", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search()

      assert is_list(ctx.results)
      assert length(ctx.results) > 0

      [first | _] = ctx.results
      assert first.question == "functional programming"
      assert first.collection == "default"
      assert is_list(first.chunks)
    end

    test "respects limit option" do
      ctx =
        Agent.new("programming", repo: Arcana.TestRepo, llm: &mock_llm/1, limit: 1)
        |> Agent.search()

      [result | _] = ctx.results
      assert length(result.chunks) <= 1
    end

    test "uses sub_questions if present" do
      ctx =
        %Context{
          question: "original",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          sub_questions: ["Elixir", "functional"]
        }
        |> Agent.search()

      assert length(ctx.results) == 2
      questions = Enum.map(ctx.results, & &1.question)
      assert "Elixir" in questions
      assert "functional" in questions
    end

    test "uses collections if present" do
      # Create a document in a specific collection
      {:ok, _} =
        Arcana.ingest("Python is also great.",
          repo: Arcana.TestRepo,
          collection: "other-langs"
        )

      ctx =
        %Context{
          question: "programming",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          collections: ["default", "other-langs"]
        }
        |> Agent.search()

      # Should have results for each collection
      collections = Enum.map(ctx.results, & &1.collection)
      assert "default" in collections
      assert "other-langs" in collections
    end
  end

  describe "answer/1" do
    test "generates answer from results" do
      llm = fn prompt ->
        assert prompt =~ "What is Elixir"
        assert prompt =~ "functional programming"
        {:ok, "Elixir is a functional language."}
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [
              %{id: "1", text: "Elixir is a functional programming language.", score: 0.9}
            ]
          }
        ]
      }

      ctx = Agent.answer(ctx)

      assert ctx.answer == "Elixir is a functional language."
      assert length(ctx.context_used) == 1
    end

    test "deduplicates chunks from multiple results" do
      llm = fn _prompt -> {:ok, "Answer"} end

      chunk = %{id: "same-id", text: "Same chunk", score: 0.9}

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{question: "q1", collection: "a", chunks: [chunk]},
          %{question: "q2", collection: "b", chunks: [chunk]}
        ]
      }

      ctx = Agent.answer(ctx)

      # Should deduplicate by id
      assert length(ctx.context_used) == 1
    end

    test "handles LLM error" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [%{question: "test", collection: "default", chunks: []}]
      }

      ctx = Agent.answer(ctx)

      assert ctx.error == :api_error
      assert is_nil(ctx.answer)
    end
  end

  describe "pipeline" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir runs on the BEAM virtual machine.",
          repo: Arcana.TestRepo
        )

      :ok
    end

    test "full pipeline from question to answer" do
      llm = fn prompt ->
        if prompt =~ "BEAM" do
          {:ok, "Elixir runs on the BEAM VM."}
        else
          {:ok, "Unknown"}
        end
      end

      ctx =
        Agent.new("What VM does Elixir use?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search()
        |> Agent.answer()

      assert ctx.answer == "Elixir runs on the BEAM VM."
      assert length(ctx.results) > 0
      assert length(ctx.context_used) > 0
    end
  end

  describe "telemetry" do
    setup do
      {:ok, _doc} = Arcana.ingest("Telemetry test content", repo: Arcana.TestRepo)
      :ok
    end

    test "emits telemetry events for search" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :search, :start],
          [:arcana, :agent, :search, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)
      |> Agent.search()

      assert_receive {:telemetry, [:arcana, :agent, :search, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :search, :stop], _, metadata}
      assert is_integer(metadata.result_count)

      :telemetry.detach(ref)
    end

    test "emits telemetry events for answer" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :answer, :start],
          [:arcana, :agent, :answer, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, "Answer"} end

      Agent.new("test", repo: Arcana.TestRepo, llm: llm)
      |> Agent.search()
      |> Agent.answer()

      assert_receive {:telemetry, [:arcana, :agent, :answer, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :answer, :stop], _, metadata}
      assert is_integer(metadata.context_chunk_count)

      :telemetry.detach(ref)
    end
  end

  describe "self-correcting search" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language built on Erlang.",
          repo: Arcana.TestRepo
        )

      :ok
    end

    test "with self_correct: false does not evaluate results" do
      call_count = :counters.new(1, [:atomics])

      llm = fn _prompt ->
        :counters.add(call_count, 1, 1)
        {:ok, "response"}
      end

      Agent.new("Elixir", repo: Arcana.TestRepo, llm: llm)
      |> Agent.search(self_correct: false)

      # LLM should not be called during search without self_correct
      assert :counters.get(call_count, 1) == 0
    end

    test "with self_correct: true evaluates result sufficiency" do
      llm = fn prompt ->
        cond do
          prompt =~ "sufficient" ->
            {:ok, ~s({"sufficient": true, "reasoning": "Results look good"})}

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Elixir", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true)

      assert is_list(ctx.results)
      # Should have iterations metadata
      [result | _] = ctx.results
      assert result.iterations == 1
    end

    test "retries search when results are insufficient" do
      attempt = :counters.new(1, [:atomics])

      # Check for "Rewrite" FIRST since rewrite prompt contains "insufficient"
      llm = fn prompt ->
        cond do
          prompt =~ "Rewrite the query" ->
            :counters.add(attempt, 1, 1)
            {:ok, ~s({"query": "Elixir programming language"})}

          prompt =~ "Are these chunks sufficient" ->
            count = :counters.get(attempt, 1)

            if count < 2 do
              :counters.add(attempt, 1, 1)
              {:ok, ~s({"sufficient": false, "reasoning": "Need more context"})}
            else
              {:ok, ~s({"sufficient": true, "reasoning": "Good now"})}
            end

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Elixir", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true, max_iterations: 3)

      [result | _] = ctx.results
      assert result.iterations > 1
    end

    test "stops after max_iterations even if insufficient" do
      # Check for "Rewrite" FIRST since rewrite prompt contains "insufficient"
      llm = fn prompt ->
        cond do
          prompt =~ "Rewrite the query" ->
            {:ok, ~s({"query": "modified query"})}

          prompt =~ "Are these chunks sufficient" ->
            {:ok, ~s({"sufficient": false, "reasoning": "Never enough"})}

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true, max_iterations: 2)

      [result | _] = ctx.results
      assert result.iterations == 2
    end

    test "telemetry includes iterations count" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [[:arcana, :agent, :search, :stop]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn prompt ->
        if prompt =~ "sufficient" do
          {:ok, ~s({"sufficient": true, "reasoning": "Good"})}
        else
          {:ok, "response"}
        end
      end

      Agent.new("Elixir", repo: Arcana.TestRepo, llm: llm)
      |> Agent.search(self_correct: true)

      assert_receive {:telemetry, [:arcana, :agent, :search, :stop], _, metadata}
      assert metadata.total_iterations == 1

      :telemetry.detach(ref)
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
