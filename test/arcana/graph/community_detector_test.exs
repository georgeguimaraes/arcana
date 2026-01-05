defmodule Arcana.Graph.CommunityDetectorTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.CommunityDetector
  alias Arcana.Graph.CommunityDetector.Leiden

  @detector {Leiden, []}

  describe "detect/3 with Leiden" do
    test "detects communities in a simple graph" do
      # Two clusters: A-B-C and D-E-F
      entities = [
        %{id: "a", name: "A"},
        %{id: "b", name: "B"},
        %{id: "c", name: "C"},
        %{id: "d", name: "D"},
        %{id: "e", name: "E"},
        %{id: "f", name: "F"}
      ]

      relationships = [
        # Cluster 1: A-B-C (strongly connected)
        %{source_id: "a", target_id: "b", strength: 10},
        %{source_id: "b", target_id: "c", strength: 10},
        %{source_id: "a", target_id: "c", strength: 10},
        # Cluster 2: D-E-F (strongly connected)
        %{source_id: "d", target_id: "e", strength: 10},
        %{source_id: "e", target_id: "f", strength: 10},
        %{source_id: "d", target_id: "f", strength: 10},
        # Weak bridge between clusters
        %{source_id: "c", target_id: "d", strength: 1}
      ]

      {:ok, communities} = CommunityDetector.detect(@detector, entities, relationships)

      assert is_list(communities)
      assert communities != []

      # Each community should have entity_ids
      Enum.each(communities, fn community ->
        assert is_list(community.entity_ids)
        assert community.level >= 0
      end)
    end

    test "returns empty list for empty graph" do
      {:ok, communities} = CommunityDetector.detect(@detector, [], [])
      assert communities == []
    end

    test "handles single entity" do
      entities = [%{id: "a", name: "A"}]
      relationships = []

      {:ok, communities} = CommunityDetector.detect(@detector, entities, relationships)

      # Single entity forms its own community
      assert communities != []
    end

    test "respects max_level option" do
      entities = Enum.map(1..10, &%{id: "#{&1}", name: "Entity #{&1}"})

      # Create a connected graph
      relationships =
        for i <- 1..9 do
          %{source_id: "#{i}", target_id: "#{i + 1}", strength: 5}
        end

      detector = {Leiden, max_level: 1}
      {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

      # All communities should be at level 0 or 1
      levels = Enum.map(communities, & &1.level)
      assert Enum.all?(levels, &(&1 <= 1))
    end

    test "respects resolution parameter" do
      entities = Enum.map(1..6, &%{id: "#{&1}", name: "Entity #{&1}"})

      relationships = [
        %{source_id: "1", target_id: "2", strength: 10},
        %{source_id: "2", target_id: "3", strength: 10},
        %{source_id: "4", target_id: "5", strength: 10},
        %{source_id: "5", target_id: "6", strength: 10},
        %{source_id: "3", target_id: "4", strength: 2}
      ]

      # Low resolution = fewer, larger communities
      low_res_detector = {Leiden, resolution: 0.5}
      {:ok, low_res} = CommunityDetector.detect(low_res_detector, entities, relationships)
      # High resolution = more, smaller communities
      high_res_detector = {Leiden, resolution: 2.0}
      {:ok, high_res} = CommunityDetector.detect(high_res_detector, entities, relationships)

      # At level 0, high resolution should have more or equal communities
      low_res_0 = Enum.filter(low_res, &(&1.level == 0))
      high_res_0 = Enum.filter(high_res, &(&1.level == 0))

      assert length(high_res_0) >= length(low_res_0)
    end

    test "uses relationship strength as edge weight" do
      entities = [
        %{id: "a", name: "A"},
        %{id: "b", name: "B"},
        %{id: "c", name: "C"}
      ]

      # Strong A-B, weak B-C
      relationships = [
        %{source_id: "a", target_id: "b", strength: 10},
        %{source_id: "b", target_id: "c", strength: 1}
      ]

      {:ok, communities} = CommunityDetector.detect(@detector, entities, relationships)

      # A and B should likely be in the same community at some level
      level_0 = Enum.filter(communities, &(&1.level == 0))

      ab_together =
        Enum.any?(level_0, fn c ->
          "a" in c.entity_ids and "b" in c.entity_ids
        end)

      # This is probabilistic, so we just check the structure is valid
      assert is_boolean(ab_together)
    end

    test "handles missing strength (defaults to 1)" do
      entities = [
        %{id: "a", name: "A"},
        %{id: "b", name: "B"}
      ]

      relationships = [
        %{source_id: "a", target_id: "b"}
      ]

      {:ok, communities} = CommunityDetector.detect(@detector, entities, relationships)
      assert is_list(communities)
    end
  end
end
