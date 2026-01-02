defmodule Arcana.Graph.GraphQueryTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.GraphQuery

  @sample_entities [
    %{id: "1", name: "OpenAI", type: :organization, embedding: [0.1, 0.2, 0.3]},
    %{id: "2", name: "Sam Altman", type: :person, embedding: [0.15, 0.25, 0.35]},
    %{id: "3", name: "GPT-4", type: :technology, embedding: [0.2, 0.3, 0.4]},
    %{id: "4", name: "Microsoft", type: :organization, embedding: [0.8, 0.7, 0.6]},
    %{id: "5", name: "Satya Nadella", type: :person, embedding: [0.85, 0.75, 0.65]}
  ]

  @sample_relationships [
    %{source_id: "2", target_id: "1", type: "LEADS"},
    %{source_id: "1", target_id: "3", type: "DEVELOPS"},
    %{source_id: "4", target_id: "1", type: "INVESTS_IN"},
    %{source_id: "5", target_id: "4", type: "LEADS"}
  ]

  @sample_chunks [
    %{id: "c1", entity_ids: ["1", "2"], content: "Sam Altman leads OpenAI"},
    %{id: "c2", entity_ids: ["1", "3"], content: "OpenAI develops GPT-4"},
    %{id: "c3", entity_ids: ["4", "1"], content: "Microsoft invests in OpenAI"},
    %{id: "c4", entity_ids: ["5", "4"], content: "Satya Nadella leads Microsoft"}
  ]

  @sample_communities [
    %{id: "comm1", level: 0, entity_ids: ["1", "2", "3"], summary: "AI research community"},
    %{id: "comm2", level: 0, entity_ids: ["4", "5"], summary: "Microsoft leadership"},
    %{
      id: "comm3",
      level: 1,
      entity_ids: ["1", "2", "3", "4", "5"],
      summary: "Tech industry overview"
    }
  ]

  describe "find_entities_by_name/3" do
    test "finds entity with exact match" do
      graph = build_graph()

      results = GraphQuery.find_entities_by_name(graph, "OpenAI")

      assert length(results) == 1
      assert hd(results).name == "OpenAI"
    end

    test "finds entities with case-insensitive match" do
      graph = build_graph()

      results = GraphQuery.find_entities_by_name(graph, "openai")

      assert length(results) == 1
      assert hd(results).name == "OpenAI"
    end

    test "finds entities with fuzzy match" do
      graph = build_graph()

      results = GraphQuery.find_entities_by_name(graph, "Open", fuzzy: true)

      assert length(results) == 1
      assert hd(results).name == "OpenAI"
    end

    test "returns empty list when no match" do
      graph = build_graph()

      results = GraphQuery.find_entities_by_name(graph, "Google")

      assert results == []
    end

    test "finds multiple matches" do
      graph = build_graph()

      results = GraphQuery.find_entities_by_name(graph, "Altman", fuzzy: true)

      assert length(results) == 1
      assert hd(results).name == "Sam Altman"
    end
  end

  describe "find_entities_by_embedding/4" do
    test "finds similar entities by embedding" do
      graph = build_graph()
      query_embedding = [0.12, 0.22, 0.32]

      results = GraphQuery.find_entities_by_embedding(graph, query_embedding, top_k: 2)

      assert length(results) == 2
      # OpenAI and Sam Altman should be most similar
      names = Enum.map(results, & &1.name)
      assert "OpenAI" in names or "Sam Altman" in names
    end

    test "respects top_k limit" do
      graph = build_graph()
      query_embedding = [0.12, 0.22, 0.32]

      results = GraphQuery.find_entities_by_embedding(graph, query_embedding, top_k: 1)

      assert length(results) == 1
    end

    test "filters by minimum similarity threshold" do
      graph = build_graph()
      # Query embedding very different from all entities
      query_embedding = [-1.0, -1.0, -1.0]

      results =
        GraphQuery.find_entities_by_embedding(graph, query_embedding,
          top_k: 5,
          min_similarity: 0.9
        )

      assert results == []
    end
  end

  describe "traverse/4" do
    test "traverses 1 hop from entity" do
      graph = build_graph()

      results = GraphQuery.traverse(graph, "1", depth: 1)

      # OpenAI connects to: Sam Altman, GPT-4, Microsoft
      related_ids = Enum.map(results, & &1.id)
      # Sam Altman
      assert "2" in related_ids
      # GPT-4
      assert "3" in related_ids
      # Microsoft
      assert "4" in related_ids
    end

    test "traverses 2 hops from entity" do
      graph = build_graph()

      results = GraphQuery.traverse(graph, "2", depth: 2)

      # Sam Altman -> OpenAI -> GPT-4, Microsoft
      related_ids = Enum.map(results, & &1.id)
      # OpenAI (1 hop)
      assert "1" in related_ids
      # GPT-4 (2 hops)
      assert "3" in related_ids
      # Microsoft (2 hops)
      assert "4" in related_ids
    end

    test "returns empty list for unknown entity" do
      graph = build_graph()

      results = GraphQuery.traverse(graph, "unknown", depth: 1)

      assert results == []
    end

    test "default depth is 1" do
      graph = build_graph()

      results = GraphQuery.traverse(graph, "5")

      # Satya Nadella -> Microsoft only (1 hop default)
      related_ids = Enum.map(results, & &1.id)
      assert "4" in related_ids
    end
  end

  describe "get_chunks_for_entities/2" do
    test "returns chunks connected to single entity" do
      graph = build_graph()

      chunks = GraphQuery.get_chunks_for_entities(graph, ["1"])

      # OpenAI is in chunks c1, c2, c3
      chunk_ids = Enum.map(chunks, & &1.id)
      assert "c1" in chunk_ids
      assert "c2" in chunk_ids
      assert "c3" in chunk_ids
    end

    test "returns chunks connected to multiple entities" do
      graph = build_graph()

      chunks = GraphQuery.get_chunks_for_entities(graph, ["1", "5"])

      # OpenAI: c1, c2, c3; Satya: c4
      chunk_ids = Enum.map(chunks, & &1.id)
      assert length(chunk_ids) == 4
    end

    test "returns unique chunks only" do
      graph = build_graph()

      # Both entities are in chunk c1
      chunks = GraphQuery.get_chunks_for_entities(graph, ["1", "2"])

      chunk_ids = Enum.map(chunks, & &1.id)
      assert Enum.uniq(chunk_ids) == chunk_ids
    end

    test "returns empty list for unknown entities" do
      graph = build_graph()

      chunks = GraphQuery.get_chunks_for_entities(graph, ["unknown"])

      assert chunks == []
    end
  end

  describe "get_community_summaries/3" do
    test "returns communities at specified level" do
      graph = build_graph()

      summaries = GraphQuery.get_community_summaries(graph, level: 0)

      assert length(summaries) == 2

      Enum.each(summaries, fn comm ->
        assert comm.level == 0
      end)
    end

    test "returns communities at higher level" do
      graph = build_graph()

      summaries = GraphQuery.get_community_summaries(graph, level: 1)

      assert length(summaries) == 1
      assert hd(summaries).summary =~ "Tech industry"
    end

    test "returns all communities when no level specified" do
      graph = build_graph()

      summaries = GraphQuery.get_community_summaries(graph)

      assert length(summaries) == 3
    end

    test "returns communities containing specific entity" do
      graph = build_graph()

      summaries = GraphQuery.get_community_summaries(graph, entity_id: "1")

      # OpenAI is in comm1 and comm3
      assert length(summaries) == 2
    end
  end

  describe "build_graph/4" do
    test "builds graph from components" do
      graph =
        GraphQuery.build_graph(
          @sample_entities,
          @sample_relationships,
          @sample_chunks,
          @sample_communities
        )

      assert is_map(graph)
      assert map_size(graph.entities) == 5
      assert length(graph.relationships) == 4
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
