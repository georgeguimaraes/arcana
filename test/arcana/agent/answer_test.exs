defmodule Arcana.Agent.AnswerTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

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

  describe "answer/1 self_correct" do
    test "accepts answer when grounded" do
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

    test "corrects answer when not grounded" do
      call_count = :counters.new(1, [:atomics])

      llm = fn prompt ->
        cond do
          prompt =~ "Answer the question" ->
            {:ok, "Initial incorrect answer."}

          prompt =~ "Evaluate if the following answer" ->
            count = :counters.get(call_count, 1)
            :counters.add(call_count, 1, 1)

            if count == 0 do
              {:ok,
               ~s({"grounded": false, "feedback": "Answer should mention functional programming."})}
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

    test "respects max_corrections limit" do
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
          %{
            question: "test",
            collection: "default",
            chunks: [%{id: "1", text: "context", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx, self_correct: true, max_corrections: 1)

      # Should stop after 1 correction even if still not grounded
      assert ctx.correction_count == 1
      assert length(ctx.corrections) == 1
    end

    test "emits telemetry events" do
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
        results: [
          %{
            question: "test",
            collection: "default",
            chunks: [%{id: "1", text: "ctx", score: 0.9}]
          }
        ]
      }

      Agent.answer(ctx, self_correct: true)

      assert_receive {:telemetry, [:arcana, :agent, :self_correct, :start], _, %{attempt: 1}}

      assert_receive {:telemetry, [:arcana, :agent, :self_correct, :stop], _,
                      %{result: :accepted}}

      :telemetry.detach(ref)
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
          results: [
            %{question: "test", collection: "default", chunks: [%{id: "1", text: "chunk"}]}
          ]
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
          results: [
            %{
              question: "test",
              collection: "default",
              chunks: [%{id: "1", text: "a"}, %{id: "2", text: "b"}]
            }
          ]
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
          results: [
            %{question: "test", collection: "default", chunks: [%{id: "1", text: "context"}]}
          ]
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
