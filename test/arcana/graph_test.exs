defmodule Arcana.GraphTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph

  describe "config/0" do
    test "returns default configuration" do
      config = Graph.config()

      assert is_map(config)
      assert config.enabled == false
      assert config.community_levels == 5
      assert config.resolution == 1.0
    end
  end

  describe "enabled?/0" do
    test "returns false by default" do
      refute Graph.enabled?()
    end
  end

  describe "search/3" do
    test "returns results from graph" do
      graph = build_sample_graph()
      entities = [%{name: "OpenAI", type: "organization"}]

      results = Graph.search(graph, entities)

      assert is_list(results)
    end

    test "supports depth option" do
      graph = build_sample_graph()
      entities = [%{name: "Sam Altman", type: "person"}]

      results = Graph.search(graph, entities, depth: 2)

      assert is_list(results)
    end
  end

  describe "fusion_search/4" do
    test "combines graph and vector results" do
      graph = build_sample_graph()
      entities = [%{name: "OpenAI", type: "organization"}]
      vector_results = [%{id: "c3", content: "GPT-4 info"}]

      results = Graph.fusion_search(graph, entities, vector_results)

      assert is_list(results)
    end

    test "respects limit option" do
      graph = build_sample_graph()
      entities = [%{name: "OpenAI", type: "organization"}]
      vector_results = [%{id: "c3", content: "GPT-4 info"}]

      results = Graph.fusion_search(graph, entities, vector_results, limit: 2)

      assert length(results) <= 2
    end
  end

  describe "community_summaries/2" do
    test "returns summaries at specified level" do
      graph = build_sample_graph()

      summaries = Graph.community_summaries(graph, level: 0)

      assert is_list(summaries)
    end

    test "returns all summaries when no level specified" do
      graph = build_sample_graph()

      summaries = Graph.community_summaries(graph)

      assert is_list(summaries)
    end
  end

  describe "build/2" do
    test "builds graph from chunks" do
      chunks = [
        %{id: "c1", text: "OpenAI is an AI company."}
      ]

      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        Graph.build(chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      assert is_map(graph_data)
      assert length(graph_data.entities) > 0
    end
  end

  defp build_sample_graph do
    alias Arcana.Graph.GraphQuery

    entities = [
      %{id: "1", name: "OpenAI", type: "organization", embedding: [0.1, 0.2, 0.3]},
      %{id: "2", name: "Sam Altman", type: "person", embedding: [0.15, 0.25, 0.35]},
      %{id: "3", name: "GPT-4", type: "technology", embedding: [0.2, 0.3, 0.4]}
    ]

    relationships = [
      %{source_id: "2", target_id: "1", type: "LEADS"},
      %{source_id: "1", target_id: "3", type: "DEVELOPS"}
    ]

    chunks = [
      %{id: "c1", entity_ids: ["1", "2"], content: "Sam Altman leads OpenAI"},
      %{id: "c2", entity_ids: ["1", "3"], content: "OpenAI develops GPT-4"}
    ]

    communities = [
      %{id: "comm1", level: 0, entity_ids: ["1", "2", "3"], summary: "AI research"}
    ]

    GraphQuery.build_graph(entities, relationships, chunks, communities)
  end
end
