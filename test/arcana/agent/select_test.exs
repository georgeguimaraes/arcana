defmodule Arcana.Agent.SelectTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

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
end
