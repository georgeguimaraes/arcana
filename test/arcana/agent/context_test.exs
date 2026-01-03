defmodule Arcana.Agent.ContextTest do
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

    test "uses config defaults for repo" do
      ctx = Agent.new("test")

      # Uses Application.get_env(:arcana, :repo) from test config
      assert ctx.repo == Arcana.TestRepo
      assert ctx.llm == nil
    end

    test "explicit options override config defaults" do
      custom_llm = fn _ -> {:ok, "custom"} end
      ctx = Agent.new("test", llm: custom_llm)

      assert ctx.repo == Arcana.TestRepo
      assert ctx.llm == custom_llm
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
