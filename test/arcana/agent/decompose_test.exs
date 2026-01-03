defmodule Arcana.Agent.DecomposeTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

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
end
