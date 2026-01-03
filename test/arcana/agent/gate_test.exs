defmodule Arcana.Agent.GateTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

  describe "gate/2" do
    test "sets skip_retrieval when LLM says answerable from knowledge" do
      llm = fn prompt ->
        assert prompt =~ "What is 2 + 2"
        {:ok, ~s({"needs_retrieval": false, "reasoning": "Basic arithmetic"})}
      end

      ctx =
        Agent.new("What is 2 + 2?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.gate()

      assert ctx.skip_retrieval == true
      assert ctx.gate_reasoning == "Basic arithmetic"
    end

    test "leaves skip_retrieval false when LLM says retrieval needed" do
      llm = fn prompt ->
        assert prompt =~ "Elixir GenServer"
        {:ok, ~s({"needs_retrieval": true, "reasoning": "Domain-specific knowledge"})}
      end

      ctx =
        Agent.new("How do Elixir GenServers work?", repo: Arcana.TestRepo, llm: llm)
        |> Agent.gate()

      assert ctx.skip_retrieval == false
      assert ctx.gate_reasoning == "Domain-specific knowledge"
    end

    test "defaults to retrieval on LLM error" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx =
        Agent.new("test question", repo: Arcana.TestRepo, llm: llm)
        |> Agent.gate()

      # Safe default: do retrieval when uncertain
      assert ctx.skip_retrieval == false
      assert is_nil(ctx.gate_reasoning)
    end

    test "defaults to retrieval on malformed LLM response" do
      llm = fn _prompt -> {:ok, "not valid json"} end

      ctx =
        Agent.new("test question", repo: Arcana.TestRepo, llm: llm)
        |> Agent.gate()

      assert ctx.skip_retrieval == false
    end

    test "accepts custom prompt function" do
      llm = fn prompt ->
        assert prompt =~ "CUSTOM GATE PROMPT"
        {:ok, ~s({"needs_retrieval": false, "reasoning": "custom"})}
      end

      custom_prompt = fn question ->
        "CUSTOM GATE PROMPT: #{question}"
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: llm)
        |> Agent.gate(prompt: custom_prompt)

      assert ctx.skip_retrieval == true
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :gate, :start],
          [:arcana, :agent, :gate, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, ~s({"needs_retrieval": true, "reasoning": "test"})} end

      Agent.new("test", repo: Arcana.TestRepo, llm: llm)
      |> Agent.gate()

      assert_receive {:telemetry, [:arcana, :agent, :gate, :start], _, %{question: "test"}}
      assert_receive {:telemetry, [:arcana, :agent, :gate, :stop], _, %{skip_retrieval: false}}

      :telemetry.detach(ref)
    end
  end

  describe "gate/2 integration with answer/1" do
    test "answer uses no-context prompt when skip_retrieval is true" do
      answer_llm = fn prompt ->
        # When skip_retrieval is true, answer should NOT include context section
        refute prompt =~ "Context:"
        assert prompt =~ "What is 2 + 2"
        {:ok, "4"}
      end

      ctx = %Context{
        question: "What is 2 + 2?",
        repo: Arcana.TestRepo,
        llm: answer_llm,
        skip_retrieval: true,
        results: nil
      }

      ctx = Agent.answer(ctx)

      assert ctx.answer == "4"
      assert ctx.context_used == []
    end

    test "answer uses context when skip_retrieval is false" do
      answer_llm = fn prompt ->
        assert prompt =~ "Context:"
        assert prompt =~ "Elixir is functional"
        {:ok, "Elixir is a functional language."}
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: answer_llm,
        skip_retrieval: false,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [%{id: "1", text: "Elixir is functional", score: 0.9}]
          }
        ]
      }

      ctx = Agent.answer(ctx)

      assert ctx.answer == "Elixir is a functional language."
      assert length(ctx.context_used) == 1
    end
  end
end
