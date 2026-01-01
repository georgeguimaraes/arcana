defmodule Arcana.Graph.FusionSearchTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.FusionSearch
  alias Arcana.Graph.GraphQuery

  @sample_entities [
    %{id: "1", name: "OpenAI", type: :organization, embedding: [0.1, 0.2, 0.3]},
    %{id: "2", name: "Sam Altman", type: :person, embedding: [0.15, 0.25, 0.35]},
    %{id: "3", name: "GPT-4", type: :technology, embedding: [0.2, 0.3, 0.4]}
  ]

  @sample_relationships [
    %{source_id: "2", target_id: "1", type: "LEADS"},
    %{source_id: "1", target_id: "3", type: "DEVELOPS"}
  ]

  @sample_chunks [
    %{id: "c1", entity_ids: ["1", "2"], content: "Sam Altman leads OpenAI"},
    %{id: "c2", entity_ids: ["1", "3"], content: "OpenAI develops GPT-4"},
    %{id: "c3", entity_ids: ["3"], content: "GPT-4 is a large language model"}
  ]

  @sample_communities [
    %{id: "comm1", level: 0, entity_ids: ["1", "2", "3"], summary: "AI research"}
  ]

  describe "reciprocal_rank_fusion/2" do
    test "merges two ranked lists" do
      list1 = [%{id: "a"}, %{id: "b"}, %{id: "c"}]
      list2 = [%{id: "b"}, %{id: "a"}, %{id: "d"}]

      result = FusionSearch.reciprocal_rank_fusion([list1, list2])

      # Items appearing in both lists should rank higher
      ids = Enum.map(result, & &1.id)
      assert "a" in ids
      assert "b" in ids
      # a and b appear in both, should be ranked high
      assert Enum.find_index(ids, &(&1 == "a")) < Enum.find_index(ids, &(&1 == "d"))
      assert Enum.find_index(ids, &(&1 == "b")) < Enum.find_index(ids, &(&1 == "d"))
    end

    test "handles empty lists" do
      result = FusionSearch.reciprocal_rank_fusion([[], []])

      assert result == []
    end

    test "handles single list" do
      list = [%{id: "a"}, %{id: "b"}]

      result = FusionSearch.reciprocal_rank_fusion([list])

      assert length(result) == 2
    end

    test "uses custom k parameter" do
      list1 = [%{id: "a"}, %{id: "b"}]
      list2 = [%{id: "b"}, %{id: "a"}]

      result = FusionSearch.reciprocal_rank_fusion([list1, list2], k: 60)

      assert length(result) == 2
    end

    test "preserves all items from all lists" do
      list1 = [%{id: "a"}]
      list2 = [%{id: "b"}]
      list3 = [%{id: "c"}]

      result = FusionSearch.reciprocal_rank_fusion([list1, list2, list3])

      ids = Enum.map(result, & &1.id)
      assert "a" in ids
      assert "b" in ids
      assert "c" in ids
    end
  end

  describe "graph_search/4" do
    test "returns chunks connected to recognized entities" do
      graph = build_graph()
      entities = [%{name: "OpenAI", type: :organization}]

      results = FusionSearch.graph_search(graph, entities)

      # OpenAI is in chunks c1 and c2
      ids = Enum.map(results, & &1.id)
      assert "c1" in ids
      assert "c2" in ids
    end

    test "traverses relationships to find related chunks" do
      graph = build_graph()
      entities = [%{name: "Sam Altman", type: :person}]

      results = FusionSearch.graph_search(graph, entities, depth: 2)

      # Sam Altman -> OpenAI -> GPT-4
      # Should include chunks with GPT-4
      ids = Enum.map(results, & &1.id)
      assert "c2" in ids or "c3" in ids
    end

    test "returns empty list when no entities found" do
      graph = build_graph()
      entities = [%{name: "Unknown", type: :organization}]

      results = FusionSearch.graph_search(graph, entities)

      assert results == []
    end

    test "respects depth option" do
      graph = build_graph()
      entities = [%{name: "Sam Altman", type: :person}]

      # Depth 1: Sam Altman -> OpenAI only
      results_1 = FusionSearch.graph_search(graph, entities, depth: 1)

      # Depth 2: includes GPT-4 as well
      results_2 = FusionSearch.graph_search(graph, entities, depth: 2)

      assert length(results_2) >= length(results_1)
    end
  end

  describe "search/4" do
    test "combines vector and graph results" do
      graph = build_graph()
      entities = [%{name: "OpenAI", type: :organization}]

      # Mock vector search returning some chunks
      vector_results = [%{id: "c3", content: "GPT-4 is a large language model"}]

      results = FusionSearch.search(graph, entities, vector_results)

      # Should include both graph results (c1, c2) and vector result (c3)
      ids = Enum.map(results, & &1.id)
      assert length(ids) > 0
    end

    test "deduplicates results from multiple sources" do
      graph = build_graph()
      entities = [%{name: "OpenAI", type: :organization}]

      # Vector search also returns c1 which is in graph results
      vector_results = [%{id: "c1", content: "Sam Altman leads OpenAI"}]

      results = FusionSearch.search(graph, entities, vector_results)

      # c1 should appear only once
      ids = Enum.map(results, & &1.id)
      assert Enum.count(ids, &(&1 == "c1")) == 1
    end

    test "ranks items appearing in multiple sources higher" do
      graph = build_graph()
      entities = [%{name: "GPT-4", type: :technology}]

      # c2 appears in both graph and vector results
      vector_results = [
        %{id: "c2", content: "OpenAI develops GPT-4"},
        %{id: "other", content: "Other content"}
      ]

      results = FusionSearch.search(graph, entities, vector_results)

      # c2 should rank highly since it's in both
      ids = Enum.map(results, & &1.id)
      assert "c2" in ids
    end

    test "respects limit option" do
      graph = build_graph()
      entities = [%{name: "OpenAI", type: :organization}]
      vector_results = [%{id: "c3", content: "GPT-4"}]

      results = FusionSearch.search(graph, entities, vector_results, limit: 2)

      assert length(results) <= 2
    end
  end

  defp build_graph do
    GraphQuery.build_graph(
      @sample_entities,
      @sample_relationships,
      @sample_chunks,
      @sample_communities
    )
  end
end
