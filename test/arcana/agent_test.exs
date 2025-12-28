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
      refute Enum.empty?(ctx.results)

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

    test "accepts custom prompt function" do
      llm = fn prompt ->
        assert prompt =~ "CUSTOM ANSWER PROMPT"
        {:ok, "Custom answer"}
      end

      custom_prompt = fn question, chunks ->
        "CUSTOM ANSWER PROMPT: #{question}, context: #{length(chunks)} chunks"
      end

      ctx = %Context{
        question: "test question",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{
            question: "test",
            collection: "default",
            chunks: [%{id: "1", text: "chunk text", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx, prompt: custom_prompt)

      assert ctx.answer == "Custom answer"
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
      refute Enum.empty?(ctx.results)
      refute Enum.empty?(ctx.context_used)
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

  describe "select/2" do
    test "selects collections based on question" do
      llm = fn prompt ->
        if prompt =~ "Which collection" do
          {:ok, ~s({"collections": ["docs", "api"], "reasoning": "Technical question"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("How do I use the API?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["docs", "api", "support"])

      assert ctx.collections == ["docs", "api"]
      assert ctx.selection_reasoning == "Technical question"
    end

    test "includes collection descriptions in prompt" do
      # Create collections with descriptions
      {:ok, _} =
        Arcana.TestRepo.insert(%Arcana.Collection{
          name: "docs",
          description: "Official documentation and tutorials"
        })

      {:ok, _} =
        Arcana.TestRepo.insert(%Arcana.Collection{
          name: "api",
          description: "API reference with function signatures"
        })

      llm = fn prompt ->
        # Verify descriptions are included in prompt
        assert prompt =~ "docs: Official documentation and tutorials"
        assert prompt =~ "api: API reference with function signatures"
        {:ok, ~s({"collections": ["docs"], "reasoning": "Docs have tutorials"})}
      end

      ctx =
        Agent.new("How do I get started?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["docs", "api"])

      assert ctx.collections == ["docs"]
    end

    test "handles collections without descriptions" do
      # Create a collection without description
      {:ok, _} =
        Arcana.TestRepo.insert(%Arcana.Collection{
          name: "misc",
          description: nil
        })

      llm = fn prompt ->
        # Should show just the name without colon
        assert prompt =~ "- misc\n" or prompt =~ "- misc"
        refute prompt =~ "misc:"
        {:ok, ~s({"collections": ["misc"]})}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["misc"])

      assert ctx.collections == ["misc"]
    end

    test "handles collections not in database" do
      # Don't create any collections - they only exist as names
      llm = fn prompt ->
        # Should still show the collection name
        assert prompt =~ "- unknown_col"
        {:ok, ~s({"collections": ["unknown_col"]})}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["unknown_col"])

      assert ctx.collections == ["unknown_col"]
    end

    test "selects single collection" do
      llm = fn prompt ->
        if prompt =~ "Which collection" do
          {:ok, ~s({"collections": ["support"], "reasoning": "Support question"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("I need help", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["docs", "support"])

      assert ctx.collections == ["support"]
    end

    test "falls back to all collections on LLM error" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx =
        Agent.new("question", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["a", "b", "c"])

      assert ctx.collections == ["a", "b", "c"]
    end

    test "falls back to all collections on malformed JSON" do
      llm = fn _prompt -> {:ok, "not json"} end

      ctx =
        Agent.new("question", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["x", "y"])

      assert ctx.collections == ["x", "y"]
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error
      }

      result = Agent.select(ctx, collections: ["a", "b"])
      assert result.error == :previous_error
      assert is_nil(result.collections)
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :select, :start],
          [:arcana, :agent, :select, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt ->
        {:ok, ~s({"collections": ["docs"], "reasoning": "docs only"})}
      end

      Agent.new("question", repo: Arcana.TestRepo, llm: llm)
      |> Agent.select(collections: ["docs", "api"])

      assert_receive {:telemetry, [:arcana, :agent, :select, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :select, :stop], _, metadata}
      assert metadata.selected_count == 1

      :telemetry.detach(ref)
    end

    test "accepts custom prompt function" do
      llm = fn prompt ->
        # Verify custom prompt was used
        assert prompt =~ "CUSTOM SELECT PROMPT"
        {:ok, ~s({"collections": ["api"]})}
      end

      custom_prompt = fn question, collections ->
        "CUSTOM SELECT PROMPT: #{question}, collections: #{inspect(collections)}"
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["docs", "api"], prompt: custom_prompt)

      assert ctx.collections == ["api"]
    end
  end

  describe "decompose/1" do
    test "breaks complex question into sub-questions" do
      llm = fn prompt ->
        if prompt =~ "Break this question" do
          {:ok,
           ~s({"sub_questions": ["What is Elixir?", "What is its syntax?"], "reasoning": "Split by topic"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("What is Elixir and what is its syntax?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose()

      assert ctx.sub_questions == ["What is Elixir?", "What is its syntax?"]
    end

    test "keeps simple questions unchanged" do
      llm = fn prompt ->
        if prompt =~ "Break this question" do
          {:ok, ~s({"sub_questions": ["What is Elixir?"], "reasoning": "Already simple"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("What is Elixir?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose()

      assert ctx.sub_questions == ["What is Elixir?"]
    end

    test "handles LLM error gracefully" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx =
        Agent.new("What is Elixir?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose()

      # On error, should use original question
      assert ctx.sub_questions == ["What is Elixir?"]
    end

    test "handles malformed JSON by using original question" do
      llm = fn _prompt -> {:ok, "not valid json"} end

      ctx =
        Agent.new("What is Elixir?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose()

      assert ctx.sub_questions == ["What is Elixir?"]
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error
      }

      result = Agent.decompose(ctx)
      assert result.error == :previous_error
      assert is_nil(result.sub_questions)
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :decompose, :start],
          [:arcana, :agent, :decompose, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt ->
        {:ok, ~s({"sub_questions": ["q1", "q2"], "reasoning": "split"})}
      end

      Agent.new("complex question", repo: Arcana.TestRepo, llm: llm)
      |> Agent.decompose()

      assert_receive {:telemetry, [:arcana, :agent, :decompose, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :decompose, :stop], _, metadata}
      assert metadata.sub_question_count == 2

      :telemetry.detach(ref)
    end

    test "accepts custom prompt function" do
      llm = fn prompt ->
        assert prompt =~ "CUSTOM DECOMPOSE"
        {:ok, ~s({"sub_questions": ["a", "b"]})}
      end

      custom_prompt = fn question ->
        "CUSTOM DECOMPOSE: #{question}"
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose(prompt: custom_prompt)

      assert ctx.sub_questions == ["a", "b"]
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
        if prompt =~ "sufficient" do
          {:ok, ~s({"sufficient": true, "reasoning": "Results look good"})}
        else
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

    test "accepts custom sufficient_prompt function" do
      llm = fn prompt ->
        assert prompt =~ "CUSTOM SUFFICIENT CHECK"
        {:ok, ~s({"sufficient": true})}
      end

      custom_prompt = fn question, chunks ->
        "CUSTOM SUFFICIENT CHECK: #{question}, chunks: #{length(chunks)}"
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true, sufficient_prompt: custom_prompt)

      assert is_list(ctx.results)
    end

    test "accepts custom rewrite_prompt function" do
      attempt = :counters.new(1, [:atomics])

      llm = fn prompt ->
        cond do
          prompt =~ "CUSTOM REWRITE" ->
            {:ok, ~s({"query": "rewritten"})}

          prompt =~ "sufficient" ->
            count = :counters.get(attempt, 1)

            if count < 1 do
              :counters.add(attempt, 1, 1)
              {:ok, ~s({"sufficient": false})}
            else
              {:ok, ~s({"sufficient": true})}
            end

          true ->
            {:ok, "response"}
        end
      end

      custom_prompt = fn question, chunks ->
        "CUSTOM REWRITE: #{question}, chunks: #{length(chunks)}"
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.search(self_correct: true, rewrite_prompt: custom_prompt)

      [result | _] = ctx.results
      assert result.iterations > 1
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
