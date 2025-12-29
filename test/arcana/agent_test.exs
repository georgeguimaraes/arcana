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

    test "uses :collection option to search specific collection" do
      {:ok, _} =
        Arcana.ingest("Ruby is a programming language.",
          repo: Arcana.TestRepo,
          collection: "ruby-docs"
        )

      ctx =
        Agent.new("programming", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(collection: "ruby-docs")

      # Should only search the specified collection
      assert length(ctx.results) == 1
      [result] = ctx.results
      assert result.collection == "ruby-docs"
    end

    test "uses :collections option to search multiple collections" do
      {:ok, _} =
        Arcana.ingest("Go is a systems language.",
          repo: Arcana.TestRepo,
          collection: "go-docs"
        )

      {:ok, _} =
        Arcana.ingest("Rust is memory safe.",
          repo: Arcana.TestRepo,
          collection: "rust-docs"
        )

      ctx =
        Agent.new("language", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(collections: ["go-docs", "rust-docs"])

      # Should search both collections
      collections = Enum.map(ctx.results, & &1.collection)
      assert "go-docs" in collections
      assert "rust-docs" in collections
    end

    test "option takes priority over ctx.collections" do
      {:ok, _} =
        Arcana.ingest("Haskell is purely functional.",
          repo: Arcana.TestRepo,
          collection: "haskell-docs"
        )

      ctx =
        %Context{
          question: "functional",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          collections: ["default"]
        }
        |> Agent.search(collection: "haskell-docs")

      # Option should override ctx.collections
      assert length(ctx.results) == 1
      [result] = ctx.results
      assert result.collection == "haskell-docs"
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

    test "accepts custom llm function" do
      context_llm = fn _prompt -> {:ok, "context llm answer"} end
      override_llm = fn _prompt -> {:ok, "override llm answer"} end

      ctx = %Context{
        question: "test question",
        repo: Arcana.TestRepo,
        llm: context_llm,
        results: [
          %{
            question: "test",
            collection: "default",
            chunks: [%{id: "1", text: "chunk text", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx, llm: override_llm)

      assert ctx.answer == "override llm answer"
    end

    test "self_correct accepts answer when grounded" do
      llm = fn prompt ->
        cond do
          prompt =~ "Answer the question" ->
            {:ok, "Elixir is a functional language."}

          prompt =~ "Evaluate if the following answer" ->
            {:ok, ~s({"grounded": true})}

          true ->
            {:ok, "response"}
        end
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [%{id: "1", text: "Elixir is a functional programming language.", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx, self_correct: true)

      assert ctx.answer == "Elixir is a functional language."
      assert ctx.correction_count == 0
      assert ctx.corrections == []
    end

    test "self_correct corrects answer when not grounded" do
      call_count = :counters.new(1, [:atomics])

      llm = fn prompt ->
        cond do
          prompt =~ "Answer the question" ->
            {:ok, "Initial incorrect answer."}

          prompt =~ "Evaluate if the following answer" ->
            count = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if count == 0 do
              {:ok, ~s({"grounded": false, "feedback": "Answer should mention functional programming."})}
            else
              {:ok, ~s({"grounded": true})}
            end

          prompt =~ "Please provide an improved answer" ->
            {:ok, "Elixir is a functional programming language."}

          true ->
            {:ok, "response"}
        end
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [%{id: "1", text: "Elixir is a functional programming language.", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx, self_correct: true)

      assert ctx.answer == "Elixir is a functional programming language."
      assert ctx.correction_count == 1
      assert length(ctx.corrections) == 1
      [{old_answer, feedback}] = ctx.corrections
      assert old_answer == "Initial incorrect answer."
      assert feedback =~ "functional programming"
    end

    test "self_correct respects max_corrections limit" do
      llm = fn prompt ->
        cond do
          prompt =~ "Answer the question" ->
            {:ok, "Answer v1"}

          prompt =~ "Evaluate if the following answer" ->
            {:ok, ~s({"grounded": false, "feedback": "needs more detail"})}

          prompt =~ "Please provide an improved answer" ->
            {:ok, "Answer v2"}

          true ->
            {:ok, "response"}
        end
      end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [
          %{question: "test", collection: "default", chunks: [%{id: "1", text: "context", score: 0.9}]}
        ]
      }

      ctx = Agent.answer(ctx, self_correct: true, max_corrections: 1)

      # Should stop after 1 correction even if still not grounded
      assert ctx.correction_count == 1
      assert length(ctx.corrections) == 1
    end

    test "self_correct emits telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :self_correct, :start],
          [:arcana, :agent, :self_correct, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn prompt ->
        cond do
          prompt =~ "Answer the question" -> {:ok, "answer"}
          prompt =~ "Evaluate" -> {:ok, ~s({"grounded": true})}
          true -> {:ok, "response"}
        end
      end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [%{question: "test", collection: "default", chunks: [%{id: "1", text: "ctx", score: 0.9}]}]
      }

      Agent.answer(ctx, self_correct: true)

      assert_receive {:telemetry, [:arcana, :agent, :self_correct, :start], _, %{attempt: 1}}
      assert_receive {:telemetry, [:arcana, :agent, :self_correct, :stop], _, %{result: :accepted}}

      :telemetry.detach(ref)
    end

    test "without self_correct sets correction_count to 0" do
      llm = fn _prompt -> {:ok, "answer"} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: [%{question: "test", collection: "default", chunks: []}]
      }

      ctx = Agent.answer(ctx)

      assert ctx.correction_count == 0
      assert ctx.corrections == []
    end
  end

  describe "pipeline" do
    setup do
      # Use words that will overlap with the query for mock embeddings
      # Mock embeddings use word hashes, so shared words = higher similarity
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language that runs on BEAM.",
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

      # Query shares "Elixir", "programming", "language" with document
      ctx =
        Agent.new("What programming language is Elixir?",
          repo: Arcana.TestRepo,
          llm: llm
        )
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

    test "accepts custom selector module" do
      defmodule TestSelector do
        @behaviour Arcana.Agent.Selector

        @impl true
        def select(_question, _collections, opts) do
          # Deterministic selection based on user context
          team = get_in(opts, [:context, :team])

          case team do
            "api" -> {:ok, ["api-reference"], "API team routing"}
            _ -> {:ok, ["docs"], "Default routing"}
          end
        end
      end

      # LLM should not be called when using custom selector
      llm = fn _prompt -> raise "LLM should not be called" end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(
          collections: ["docs", "api-reference"],
          selector: TestSelector,
          context: %{team: "api"}
        )

      assert ctx.collections == ["api-reference"]
      assert ctx.selection_reasoning == "API team routing"
    end

    test "accepts custom selector function" do
      # LLM should not be called when using custom selector
      llm = fn _prompt -> raise "LLM should not be called" end

      custom_selector = fn question, _collections, _opts ->
        if question =~ "API" do
          {:ok, ["api-docs"], "Question mentions API"}
        else
          {:ok, ["general"], "General query"}
        end
      end

      ctx =
        Agent.new("How do I use the API?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["general", "api-docs"], selector: custom_selector)

      assert ctx.collections == ["api-docs"]
      assert ctx.selection_reasoning == "Question mentions API"
    end

    test "selector receives collections with descriptions" do
      {:ok, _} =
        Arcana.TestRepo.insert(%Arcana.Collection{
          name: "products",
          description: "Product catalog data"
        })

      llm = fn _prompt -> raise "LLM should not be called" end

      selector = fn _question, collections, _opts ->
        # Verify collections have descriptions
        assert Enum.find(collections, fn {name, _desc} -> name == "products" end)
        {_name, description} = Enum.find(collections, fn {name, _} -> name == "products" end)
        assert description == "Product catalog data"

        {:ok, ["products"], "verified descriptions"}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["products"], selector: selector)

      assert ctx.collections == ["products"]
    end

    test "falls back to all collections when custom selector returns error" do
      llm = fn _prompt -> {:ok, ~s({"collections": ["fallback"]})} end

      selector = fn _question, _collections, _opts ->
        {:error, :something_went_wrong}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["a", "b", "c"], selector: selector)

      # Should fall back to all collections
      assert ctx.collections == ["a", "b", "c"]
    end

    test "uses Arcana.Selector.LLM as default selector" do
      llm = fn prompt ->
        assert prompt =~ "Which collection"
        {:ok, ~s({"collections": ["docs"], "reasoning": "LLM selected"})}
      end

      ctx =
        Agent.new("question", repo: Arcana.TestRepo, llm: llm)
        |> Agent.select(collections: ["docs", "api"])

      assert ctx.collections == ["docs"]
      assert ctx.selection_reasoning == "LLM selected"
    end

    test "accepts custom llm option" do
      default_llm = fn _prompt -> raise "default LLM should not be called" end

      custom_llm = fn prompt ->
        assert prompt =~ "Which collection"
        {:ok, ~s({"collections": ["api"], "reasoning": "Custom LLM selected"})}
      end

      ctx =
        Agent.new("question", repo: Arcana.TestRepo, llm: default_llm)
        |> Agent.select(collections: ["docs", "api"], llm: custom_llm)

      assert ctx.collections == ["api"]
      assert ctx.selection_reasoning == "Custom LLM selected"
    end
  end

  describe "decompose/1" do
    test "breaks complex question into sub-questions" do
      llm = fn prompt ->
        if prompt =~ "decompose this question" do
          {:ok, ~s({"sub_questions": ["What is Elixir?", "What is its syntax?"]})}
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
        if prompt =~ "decompose this question" do
          {:ok, ~s({"sub_questions": ["What is Elixir?"]})}
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

    test "accepts custom llm function" do
      context_llm = fn _prompt -> {:ok, ~s({"sub_questions": ["context"]})} end
      override_llm = fn _prompt -> {:ok, ~s({"sub_questions": ["override"]})} end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: context_llm)
        |> Agent.decompose(llm: override_llm)

      assert ctx.sub_questions == ["override"]
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

  describe "rewrite/2" do
    test "rewrites conversational input into clear search query" do
      llm = fn prompt ->
        if prompt =~ "rewrite this input" do
          {:ok, "compare Elixir and Go for web services"}
        else
          {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Hey, I want to compare Elixir and Go lang for building web services",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()

      assert ctx.rewritten_query == "compare Elixir and Go for web services"
    end

    test "rewritten query is used by expand/2" do
      llm = fn prompt ->
        cond do
          prompt =~ "rewrite this input" ->
            {:ok, "compare Elixir and Go"}

          prompt =~ "expand this query" ->
            # Should receive the rewritten query, not the original
            if prompt =~ "compare Elixir and Go" do
              {:ok, "compare Elixir Go Golang BEAM concurrency"}
            else
              {:ok, "wrong query received"}
            end

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Hey now, I want to compare Elixir and Go lang",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()
        |> Agent.expand()

      assert ctx.rewritten_query == "compare Elixir and Go"
      assert ctx.expanded_query == "compare Elixir Go Golang BEAM concurrency"
    end

    test "rewritten query is used by decompose/2" do
      llm = fn prompt ->
        cond do
          prompt =~ "rewrite this input" ->
            {:ok, "compare Elixir and Go"}

          prompt =~ "decompose this question" ->
            # Should receive the rewritten query, not the original
            if prompt =~ "compare Elixir and Go" do
              {:ok, ~s({"sub_questions": ["What is Elixir?", "What is Go?"]})}
            else
              {:ok, ~s({"sub_questions": ["wrong query"]})}
            end

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Hey, can you tell me about Elixir vs Go?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()
        |> Agent.decompose()

      assert ctx.rewritten_query == "compare Elixir and Go"
      assert ctx.sub_questions == ["What is Elixir?", "What is Go?"]
    end

    test "expanded query is used by decompose/2 (full chain)" do
      llm = fn prompt ->
        cond do
          prompt =~ "rewrite this input" ->
            {:ok, "compare ML and DL"}

          prompt =~ "expand this query" ->
            {:ok, "compare ML machine learning and DL deep learning"}

          prompt =~ "decompose this question" ->
            # Should receive the expanded query with synonyms
            if prompt =~ "machine learning" and prompt =~ "deep learning" do
              {:ok, ~s({"sub_questions": ["What is ML machine learning?", "What is DL deep learning?"]})}
            else
              {:ok, ~s({"sub_questions": ["missing expansions"]})}
            end

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        Agent.new("Hey, compare ML and DL for me",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.rewrite()
        |> Agent.expand()
        |> Agent.decompose()

      assert ctx.rewritten_query == "compare ML and DL"
      assert ctx.expanded_query == "compare ML machine learning and DL deep learning"
      assert ctx.sub_questions == ["What is ML machine learning?", "What is DL deep learning?"]
    end

    test "handles LLM error gracefully" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx =
        Agent.new("Hey, tell me about Elixir", repo: Arcana.TestRepo, llm: llm)
        |> Agent.rewrite()

      assert is_nil(ctx.rewritten_query)
      assert is_nil(ctx.error)
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error
      }

      result = Agent.rewrite(ctx)
      assert result.error == :previous_error
      assert is_nil(result.rewritten_query)
    end

    test "accepts custom prompt function" do
      custom_prompt = fn question ->
        "Custom rewrite: #{question}"
      end

      llm = fn prompt ->
        if prompt =~ "Custom rewrite:" do
          {:ok, "custom rewritten query"}
        else
          {:ok, "default response"}
        end
      end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: llm)
        |> Agent.rewrite(prompt: custom_prompt)

      assert ctx.rewritten_query == "custom rewritten query"
    end

    test "accepts custom llm function" do
      context_llm = fn _prompt -> {:ok, "context llm response"} end
      override_llm = fn _prompt -> {:ok, "override llm response"} end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: context_llm)
        |> Agent.rewrite(llm: override_llm)

      assert ctx.rewritten_query == "override llm response"
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :rewrite, :start],
          [:arcana, :agent, :rewrite, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, "rewritten"} end

      Agent.new("Hey, tell me about Elixir", repo: Arcana.TestRepo, llm: llm)
      |> Agent.rewrite()

      assert_receive {[:arcana, :agent, :rewrite, :start], _, %{question: _}}
      assert_receive {[:arcana, :agent, :rewrite, :stop], _, %{rewritten_query: "rewritten"}}

      :telemetry.detach(ref)
    end
  end

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

  describe "rerank/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      {:ok, _doc} =
        Arcana.ingest("The weather is sunny today.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      {:ok, _doc} =
        Arcana.ingest("Elixir runs on the BEAM virtual machine.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      :ok
    end

    test "reranks and filters chunks by score threshold" do
      llm = fn prompt ->
        cond do
          prompt =~ "functional programming" ->
            {:ok, ~s({"score": 9, "reasoning": "highly relevant"})}

          prompt =~ "weather" ->
            {:ok, ~s({"score": 2, "reasoning": "not relevant"})}

          prompt =~ "BEAM virtual machine" ->
            {:ok, ~s({"score": 8, "reasoning": "relevant context"})}

          prompt =~ "Rate how relevant" ->
            {:ok, ~s({"score": 5, "reasoning": "default"})}

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "What is Elixir?",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank(threshold: 7)

      # Should filter out the weather chunk
      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      refute Enum.any?(all_chunks, &(&1.text =~ "weather"))
      assert Enum.any?(all_chunks, &(&1.text =~ "functional"))
    end

    test "re-sorts chunks by score descending" do
      # LLM gives higher score to BEAM chunk
      llm = fn prompt ->
        cond do
          prompt =~ "BEAM" ->
            {:ok, ~s({"score": 10, "reasoning": "best match"})}

          prompt =~ "functional" ->
            {:ok, ~s({"score": 8, "reasoning": "good match"})}

          prompt =~ "Rate how relevant" ->
            {:ok, ~s({"score": 9, "reasoning": "default high"})}

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "BEAM VM",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank(threshold: 7)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      # First chunk should be the BEAM one (highest score)
      assert hd(all_chunks).text =~ "BEAM"
    end

    test "uses default LLM reranker when no reranker specified" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 8, "reasoning": "relevant"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank()

      # Should have reranked results
      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker module" do
      defmodule TestReranker do
        @behaviour Arcana.Agent.Reranker

        @impl Arcana.Agent.Reranker
        def rerank(_question, chunks, _opts) do
          # Just reverse the chunks as a simple test
          {:ok, Enum.reverse(chunks)}
        end
      end

      llm = fn _prompt -> {:ok, "response"} end

      ctx =
        %Context{
          question: "Elixir programming",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank(reranker: TestReranker)

      # Reranker was called (chunks are reversed)
      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker function" do
      llm = fn _prompt -> {:ok, "response"} end

      custom_reranker = fn _question, chunks, _opts ->
        # Filter to only chunks containing "Elixir"
        filtered = Enum.filter(chunks, &(&1.text =~ "Elixir"))
        {:ok, filtered}
      end

      ctx =
        %Context{
          question: "programming language",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank(reranker: custom_reranker)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      assert Enum.all?(all_chunks, &(&1.text =~ "Elixir"))
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error,
        results: []
      }

      result = Agent.rerank(ctx)

      assert result.error == :previous_error
    end

    test "handles empty results gracefully" do
      llm = fn _prompt -> {:ok, "response"} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: []
      }

      result = Agent.rerank(ctx)

      assert result.results == []
      assert is_nil(result.error)
    end

    test "emits telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:arcana, :agent, :rerank, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 8, "reasoning": "relevant"})}
        else
          {:ok, "response"}
        end
      end

      %Context{
        question: "Elixir",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 10,
        threshold: 0.0,
        collections: ["test-rerank"]
      }
      |> Agent.search()
      |> Agent.rerank()

      assert_receive {:telemetry, [:arcana, :agent, :rerank, :stop], _, stop_meta}
      assert is_integer(stop_meta.chunks_before)
      assert is_integer(stop_meta.chunks_after)

      :telemetry.detach(ref)
    end

    test "stores rerank scores in context" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 9, "reasoning": "good"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank()

      assert is_map(ctx.rerank_scores)
      refute Enum.empty?(ctx.rerank_scores)
    end

    test "accepts custom llm option" do
      default_llm = fn _prompt -> raise "default LLM should not be called" end

      custom_llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 9, "reasoning": "custom llm scored"})}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: default_llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Agent.search()
        |> Agent.rerank(llm: custom_llm)

      # Rerank should succeed using custom LLM
      refute Enum.empty?(ctx.results)
      assert is_map(ctx.rerank_scores)
    end
  end

  describe "custom rewriter" do
    test "accepts custom rewriter module" do
      defmodule TestRewriter do
        @behaviour Arcana.Agent.Rewriter

        @impl true
        def rewrite(question, _opts) do
          {:ok, String.downcase(question)}
        end
      end

      # LLM should not be called when using custom rewriter
      llm = fn _prompt -> raise "LLM should not be called" end

      ctx =
        Agent.new("HELLO WORLD", repo: Arcana.TestRepo, llm: llm)
        |> Agent.rewrite(rewriter: TestRewriter)

      assert ctx.rewritten_query == "hello world"
    end

    test "accepts custom rewriter function" do
      llm = fn _prompt -> raise "LLM should not be called" end

      custom_rewriter = fn question, _opts ->
        {:ok, String.reverse(question)}
      end

      ctx =
        Agent.new("hello", repo: Arcana.TestRepo, llm: llm)
        |> Agent.rewrite(rewriter: custom_rewriter)

      assert ctx.rewritten_query == "olleh"
    end

    test "falls back to nil on rewriter error" do
      custom_rewriter = fn _question, _opts ->
        {:error, :rewrite_failed}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.rewrite(rewriter: custom_rewriter)

      assert is_nil(ctx.rewritten_query)
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

  describe "custom decomposer" do
    test "accepts custom decomposer module" do
      defmodule TestDecomposer do
        @behaviour Arcana.Agent.Decomposer

        @impl true
        def decompose(question, _opts) do
          parts = String.split(question, " and ")
          {:ok, parts}
        end
      end

      llm = fn _prompt -> raise "LLM should not be called" end

      ctx =
        Agent.new("Elixir and Go", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose(decomposer: TestDecomposer)

      assert ctx.sub_questions == ["Elixir", "Go"]
    end

    test "accepts custom decomposer function" do
      llm = fn _prompt -> raise "LLM should not be called" end

      custom_decomposer = fn question, _opts ->
        {:ok, [question, question <> " detailed"]}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.decompose(decomposer: custom_decomposer)

      assert ctx.sub_questions == ["test", "test detailed"]
    end
  end

  describe "custom searcher" do
    test "accepts custom searcher module" do
      defmodule TestSearcher do
        @behaviour Arcana.Agent.Searcher

        @impl true
        def search(_question, _collection, _opts) do
          chunks = [
            %{id: "custom-1", text: "Custom search result", metadata: %{}, similarity: 0.9}
          ]

          {:ok, chunks}
        end
      end

      ctx =
        Agent.new("anything", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: TestSearcher)

      [result | _] = ctx.results
      [chunk | _] = result.chunks
      assert chunk.id == "custom-1"
      assert chunk.text == "Custom search result"
    end

    test "accepts custom searcher function" do
      custom_searcher = fn question, _collection, _opts ->
        {:ok, [%{id: "fn-1", text: "Function search: #{question}", metadata: %{}, similarity: 1.0}]}
      end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: custom_searcher)

      [result | _] = ctx.results
      [chunk | _] = result.chunks
      assert chunk.id == "fn-1"
      assert chunk.text =~ "test query"
    end

    test "returns empty results on searcher error" do
      custom_searcher = fn _question, _collection, _opts ->
        {:error, :search_failed}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: custom_searcher)

      [result | _] = ctx.results
      assert result.chunks == []
    end
  end

  describe "custom answerer" do
    test "accepts custom answerer module" do
      defmodule TestAnswerer do
        @behaviour Arcana.Agent.Answerer

        @impl true
        def answer(question, chunks, _opts) do
          {:ok, "Custom answer for: #{question} with #{length(chunks)} chunks"}
        end
      end

      ctx =
        %Context{
          question: "test question",
          repo: Arcana.TestRepo,
          llm: fn _ -> raise "LLM should not be called" end,
          limit: 5,
          threshold: 0.5,
          results: [%{question: "test", collection: "default", chunks: [%{id: "1", text: "chunk"}]}]
        }
        |> Agent.answer(answerer: TestAnswerer)

      assert ctx.answer == "Custom answer for: test question with 1 chunks"
    end

    test "accepts custom answerer function" do
      custom_answerer = fn _question, chunks, _opts ->
        {:ok, "Function answer: #{length(chunks)} chunks"}
      end

      ctx =
        %Context{
          question: "test",
          repo: Arcana.TestRepo,
          llm: fn _ -> raise "LLM should not be called" end,
          limit: 5,
          threshold: 0.5,
          results: [%{question: "test", collection: "default", chunks: [%{id: "1", text: "a"}, %{id: "2", text: "b"}]}]
        }
        |> Agent.answer(answerer: custom_answerer)

      assert ctx.answer == "Function answer: 2 chunks"
    end

    test "sets error on answerer error" do
      custom_answerer = fn _question, _chunks, _opts ->
        {:error, :answer_failed}
      end

      ctx =
        %Context{
          question: "test",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          results: [%{question: "test", collection: "default", chunks: []}]
        }
        |> Agent.answer(answerer: custom_answerer)

      assert ctx.error == :answer_failed
    end

    test "self_correct still works with custom answerer" do
      eval_count = :counters.new(1, [:atomics])

      # Custom answerer generates initial answer
      custom_answerer = fn _question, _chunks, _opts ->
        {:ok, "Initial answer from custom answerer"}
      end

      # LLM handles evaluation and correction
      llm = fn prompt ->
        cond do
          prompt =~ "Evaluate if the following answer" ->
            count = :counters.get(eval_count, 1)
            :counters.add(eval_count, 1, 1)

            if count == 0 do
              # First evaluation - mark as not grounded
              {:ok, ~s({"grounded": false, "feedback": "Please improve"})}
            else
              # Second evaluation - accept the corrected answer
              {:ok, ~s({"grounded": true})}
            end

          prompt =~ "Please provide an improved answer" ->
            # Correction prompt - LLM generates corrected answer
            {:ok, "Corrected answer from LLM"}

          true ->
            {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "test",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 5,
          threshold: 0.5,
          results: [%{question: "test", collection: "default", chunks: [%{id: "1", text: "context"}]}]
        }
        |> Agent.answer(answerer: custom_answerer, self_correct: true)

      # Final answer is from the LLM correction, not the custom answerer
      assert ctx.answer == "Corrected answer from LLM"
      assert ctx.correction_count == 1
      # History contains the original custom answerer output and feedback
      assert [{original, feedback}] = ctx.corrections
      assert original == "Initial answer from custom answerer"
      assert feedback == "Please improve"
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
