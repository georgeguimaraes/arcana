defmodule Arcana.LLMTest do
  use ExUnit.Case, async: true

  alias Arcana.LLM

  describe "Arcana.LLM protocol" do
    test "works with anonymous functions (arity 2)" do
      llm = fn prompt, context ->
        {:ok, "Answer to: #{prompt} with #{length(context)} chunks"}
      end

      context = [%{text: "chunk1"}, %{text: "chunk2"}]
      {:ok, result} = LLM.complete(llm, "test question", context, [])

      assert result == "Answer to: test question with 2 chunks"
    end

    test "works with anonymous functions (arity 1) for rewriters" do
      llm = fn prompt ->
        {:ok, "Expanded: #{prompt}"}
      end

      {:ok, result} = LLM.complete(llm, "short query", [], [])

      assert result == "Expanded: short query"
    end

    test "passes through errors from functions" do
      llm = fn _prompt, _context ->
        {:error, :api_error}
      end

      assert {:error, :api_error} = LLM.complete(llm, "test", [], [])
    end
  end

  describe "Req.LLM integration" do
    test "works with OpenAI model string" do
      model = "openai:gpt-4o-mini"
      assert LLM.impl_for(model) != nil
    end

    test "works with Anthropic model string" do
      model = "anthropic:claude-sonnet-4-20250514"
      assert LLM.impl_for(model) != nil
    end
  end

  describe "Helpers.chat/3" do
    test "function/2 mock receives context and tools" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("hello")])
      tools = [:sentinel_tool]

      mock = fn received_ctx, received_tools ->
        assert received_ctx == context
        assert received_tools == tools
        {:ok, mock_response("answer text")}
      end

      assert {:ok, %ReqLLM.Response{}} = LLM.Helpers.chat(mock, context, tools: tools)
    end

    test "function/2 mock defaults to empty tools" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("hello")])

      mock = fn _ctx, received_tools ->
        assert received_tools == []
        {:ok, mock_response("ok")}
      end

      assert {:ok, _} = LLM.Helpers.chat(mock, context, [])
    end

    test "function/2 mock passes through errors" do
      context = ReqLLM.Context.new([ReqLLM.Context.user("hello")])

      mock = fn _ctx, _tools -> {:error, :rate_limited} end

      assert {:error, :rate_limited} = LLM.Helpers.chat(mock, context, [])
    end

    test "tuple config is accepted by guard" do
      llm = {"openai:gpt-4o-mini", api_key: "test-key"}
      assert is_binary(elem(llm, 0))
      assert is_list(elem(llm, 1))
    end

    test "returns full ReqLLM.Response with tool calls" do
      tool_call = ReqLLM.ToolCall.new("call-1", "grep", JSON.encode!(%{pattern: "test"}))

      response = %ReqLLM.Response{
        id: "resp-1",
        model: "mock",
        context: nil,
        message: ReqLLM.Context.assistant("", tool_calls: [tool_call]),
        finish_reason: :tool_calls,
        usage: %{input_tokens: 10, output_tokens: 5}
      }

      mock = fn _ctx, _tools -> {:ok, response} end
      context = ReqLLM.Context.new([ReqLLM.Context.user("test")])

      {:ok, result} = LLM.Helpers.chat(mock, context, tools: [])

      assert result.finish_reason == :tool_calls
      assert result.usage == %{input_tokens: 10, output_tokens: 5}
      classified = ReqLLM.Response.classify(result)
      assert classified.type == :tool_calls
      assert length(classified.tool_calls) == 1
    end

    test "returns full ReqLLM.Response with text answer" do
      mock = fn _ctx, _tools -> {:ok, mock_response("the answer")} end
      context = ReqLLM.Context.new([ReqLLM.Context.user("test")])

      {:ok, result} = LLM.Helpers.chat(mock, context, [])

      assert ReqLLM.Response.text(result) == "the answer"
      assert result.finish_reason == :stop
    end

    test "usage tracking is preserved" do
      usage = %{input_tokens: 42, output_tokens: 17}

      mock = fn _ctx, _tools ->
        {:ok,
         %ReqLLM.Response{
           id: "r1",
           model: "mock",
           context: nil,
           message: ReqLLM.Context.assistant("ok"),
           finish_reason: :stop,
           usage: usage
         }}
      end

      context = ReqLLM.Context.new([ReqLLM.Context.user("test")])
      {:ok, result} = LLM.Helpers.chat(mock, context, [])

      assert result.usage.input_tokens == 42
      assert result.usage.output_tokens == 17
    end
  end

  defp mock_response(text) do
    %ReqLLM.Response{
      id: "resp-#{System.unique_integer([:positive])}",
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end
end
