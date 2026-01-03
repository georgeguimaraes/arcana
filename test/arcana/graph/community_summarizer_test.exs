defmodule Arcana.Graph.CommunitySummarizerTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.CommunitySummarizer

  describe "summarize/4" do
    test "generates summary for community" do
      entities = [
        %{name: "Sam Altman", type: "person", description: "CEO of OpenAI"},
        %{name: "OpenAI", type: "organization", description: "AI research company"}
      ]

      relationships = [
        %{source: "Sam Altman", target: "OpenAI", type: "LEADS", description: "CEO role"}
      ]

      llm = fn _prompt, _ctx, _opts ->
        {:ok, "This community focuses on OpenAI leadership, with Sam Altman as CEO."}
      end

      {:ok, summary} = CommunitySummarizer.summarize(entities, relationships, llm)

      assert is_binary(summary)
      assert summary =~ "OpenAI"
    end

    test "handles empty entities" do
      llm = fn _prompt, _ctx, _opts ->
        {:ok, "Empty community with no entities."}
      end

      {:ok, summary} = CommunitySummarizer.summarize([], [], llm)

      assert is_binary(summary)
    end

    test "handles LLM errors" do
      entities = [%{name: "Test", type: "person"}]

      llm = fn _prompt, _ctx, _opts ->
        {:error, :api_error}
      end

      assert {:error, :api_error} = CommunitySummarizer.summarize(entities, [], llm)
    end
  end

  describe "build_prompt/2" do
    test "includes entity names and types" do
      entities = [
        %{name: "OpenAI", type: "organization"},
        %{name: "Sam Altman", type: "person"}
      ]

      prompt = CommunitySummarizer.build_prompt(entities, [])

      assert prompt =~ "OpenAI"
      assert prompt =~ "Sam Altman"
      assert prompt =~ "organization"
      assert prompt =~ "person"
    end

    test "includes relationship information" do
      entities = [%{name: "A", type: "person"}, %{name: "B", type: "person"}]

      relationships = [
        %{source: "A", target: "B", type: "KNOWS", description: "Friends"}
      ]

      prompt = CommunitySummarizer.build_prompt(entities, relationships)

      assert prompt =~ "KNOWS"
      assert prompt =~ "Friends"
    end
  end

  describe "needs_regeneration?/2" do
    test "returns true when change_count exceeds threshold" do
      community = %{change_count: 10, dirty: false, summary: "Existing summary"}

      assert CommunitySummarizer.needs_regeneration?(community, threshold: 5)
    end

    test "returns false when change_count below threshold" do
      community = %{change_count: 3, dirty: false, summary: "Existing summary"}

      refute CommunitySummarizer.needs_regeneration?(community, threshold: 5)
    end

    test "returns true when dirty flag is set" do
      community = %{change_count: 0, dirty: true}

      assert CommunitySummarizer.needs_regeneration?(community, threshold: 5)
    end

    test "returns true when no summary exists" do
      community = %{change_count: 0, dirty: false, summary: nil}

      assert CommunitySummarizer.needs_regeneration?(community, threshold: 5)
    end

    test "returns false when summary exists and not dirty" do
      community = %{change_count: 2, dirty: false, summary: "Existing summary"}

      refute CommunitySummarizer.needs_regeneration?(community, threshold: 5)
    end

    test "uses default threshold of 10" do
      community = %{change_count: 8, dirty: false, summary: "Exists"}
      refute CommunitySummarizer.needs_regeneration?(community)

      community = %{change_count: 12, dirty: false, summary: "Exists"}
      assert CommunitySummarizer.needs_regeneration?(community)
    end
  end

  describe "reset_change_tracking/1" do
    test "returns map with zeroed change_count and dirty false" do
      result = CommunitySummarizer.reset_change_tracking()

      assert result == %{change_count: 0, dirty: false}
    end
  end
end
