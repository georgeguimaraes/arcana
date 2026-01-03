defmodule Arcana.Graph.GraphStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.GraphStore
  alias Arcana.Graph.GraphStore.Memory

  setup do
    {:ok, pid} = Memory.start_link([])
    {:ok, pid: pid}
  end

  describe "dispatch via GraphStore" do
    test "works with graph_store: {:memory, pid: pid} option", %{pid: pid} do
      collection_id = "dispatch-test"
      entities = [%{name: "Test", type: "thing"}]

      {:ok, id_map} =
        GraphStore.persist_entities(collection_id, entities, graph_store: {:memory, pid: pid})

      assert Map.has_key?(id_map, "Test")

      found = GraphStore.find_entities(collection_id, graph_store: {:memory, pid: pid})
      assert length(found) == 1
      assert hd(found).name == "Test"
    end
  end

  describe "persist_entities/3" do
    test "stores entities and returns id map", %{pid: pid} do
      collection_id = "col-1"

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      assert map_size(id_map) == 2
      assert Map.has_key?(id_map, "Alice")
      assert Map.has_key?(id_map, "Bob")
    end

    test "deduplicates entities by name", %{pid: pid} do
      collection_id = "col-1"

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Alice", type: "person"}
      ]

      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      assert map_size(id_map) == 1
    end

    test "returns existing ids on upsert", %{pid: pid} do
      collection_id = "col-1"
      entities = [%{name: "Alice", type: "person"}]

      {:ok, id_map1} = Memory.persist_entities(collection_id, entities, pid: pid)
      {:ok, id_map2} = Memory.persist_entities(collection_id, entities, pid: pid)

      assert id_map1["Alice"] == id_map2["Alice"]
    end
  end

  describe "persist_relationships/3" do
    test "stores relationships between entities", %{pid: pid} do
      collection_id = "col-1"

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      relationships = [
        %{source: "Alice", target: "Bob", type: "knows"}
      ]

      assert :ok = Memory.persist_relationships(relationships, id_map, pid: pid)
    end

    test "skips relationships with missing entities", %{pid: pid} do
      id_map = %{"Alice" => Ecto.UUID.generate()}
      relationships = [%{source: "Alice", target: "Unknown", type: "knows"}]

      assert :ok = Memory.persist_relationships(relationships, id_map, pid: pid)
    end
  end

  describe "persist_mentions/3" do
    test "stores entity mentions", %{pid: pid} do
      collection_id = "col-1"
      entities = [%{name: "Alice", type: "person"}]
      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      mentions = [
        %{entity_name: "Alice", chunk_id: "chunk-1"}
      ]

      assert :ok = Memory.persist_mentions(mentions, id_map, pid: pid)
    end
  end

  describe "search/3" do
    test "finds chunks by entity names and scores by mention count", %{pid: pid} do
      collection_id = "col-1"

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      # Alice mentioned in chunk-1 and chunk-2, Bob only in chunk-1
      mentions = [
        %{entity_name: "Alice", chunk_id: "chunk-1"},
        %{entity_name: "Bob", chunk_id: "chunk-1"},
        %{entity_name: "Alice", chunk_id: "chunk-2"}
      ]

      :ok = Memory.persist_mentions(mentions, id_map, pid: pid)

      results = Memory.search(["Alice", "Bob"], [collection_id], pid: pid)

      assert length(results) == 2
      # chunk-1 has 2 mentions (Alice + Bob), chunk-2 has 1 mention (Alice)
      [first, second] = results
      assert first.chunk_id == "chunk-1"
      assert first.score > second.score
    end

    test "returns empty list when no entities match", %{pid: pid} do
      results = Memory.search(["Unknown"], nil, pid: pid)
      assert results == []
    end
  end

  describe "find_entities/2" do
    test "returns all entities in collection", %{pid: pid} do
      collection_id = "col-1"
      other_collection = "col-2"

      entities1 = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      entities2 = [%{name: "Other", type: "person"}]

      {:ok, _} = Memory.persist_entities(collection_id, entities1, pid: pid)
      {:ok, _} = Memory.persist_entities(other_collection, entities2, pid: pid)

      entities = Memory.find_entities(collection_id, pid: pid)

      assert length(entities) == 2
      names = Enum.map(entities, & &1.name)
      assert "Alice" in names
      assert "Bob" in names
    end
  end

  describe "find_related_entities/3" do
    test "finds entities connected within depth", %{pid: pid} do
      collection_id = "col-1"

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"},
        %{name: "Charlie", type: "person"}
      ]

      {:ok, id_map} = Memory.persist_entities(collection_id, entities, pid: pid)

      # Alice -> Bob -> Charlie
      relationships = [
        %{source: "Alice", target: "Bob", type: "knows"},
        %{source: "Bob", target: "Charlie", type: "knows"}
      ]

      :ok = Memory.persist_relationships(relationships, id_map, pid: pid)

      # From Alice, depth 1 should find Bob
      alice_id = id_map["Alice"]
      related = Memory.find_related_entities(alice_id, 1, pid: pid)
      names = Enum.map(related, & &1.name)

      assert "Alice" in names
      assert "Bob" in names
      refute "Charlie" in names

      # From Alice, depth 2 should find Bob and Charlie
      related_deep = Memory.find_related_entities(alice_id, 2, pid: pid)
      names_deep = Enum.map(related_deep, & &1.name)

      assert "Alice" in names_deep
      assert "Bob" in names_deep
      assert "Charlie" in names_deep
    end
  end

  describe "persist_communities/3 and get_community_summaries/2" do
    test "stores and retrieves communities", %{pid: pid} do
      collection_id = "col-1"

      communities = [
        %{id: "comm-1", level: 0, summary: "A group of friends", entity_ids: ["e1", "e2"]},
        %{id: "comm-2", level: 1, summary: "Work colleagues", entity_ids: ["e3"]}
      ]

      assert :ok = Memory.persist_communities(collection_id, communities, pid: pid)

      retrieved = Memory.get_community_summaries(collection_id, pid: pid)

      assert length(retrieved) == 2
      summaries = Enum.map(retrieved, & &1.summary)
      assert "A group of friends" in summaries
      assert "Work colleagues" in summaries
    end
  end
end
