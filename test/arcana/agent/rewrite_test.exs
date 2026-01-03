defmodule Arcana.Agent.RewriteTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

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
              {:ok,
               ~s({"sub_questions": ["What is ML machine learning?", "What is DL deep learning?"]})}
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

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
