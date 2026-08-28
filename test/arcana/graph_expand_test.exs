defmodule Arcana.GraphExpandTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Graph
  alias Arcana.Graph.{Entity, EntityMention, Relationship, RelationshipEvidence}

  defp create_collection(name) do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp create_entity(collection, name, type \\ "person") do
    entity =
      %Entity{}
      |> Entity.changeset(%{name: name, type: type, collection_id: collection.id})
      |> Repo.insert!()

    add_evidence(entity, collection, :completed)
    entity
  end

  defp add_evidence(entity, collection, status) do
    document =
      %Document{}
      |> Document.changeset(%{
        content: "#{status} evidence",
        status: status,
        collection_id: collection.id
      })
      |> Repo.insert!()

    chunk =
      %Chunk{}
      |> Chunk.changeset(%{
        text: "#{status} evidence",
        embedding: List.duplicate(0.1, 384),
        document_id: document.id
      })
      |> Repo.insert!()

    %EntityMention{}
    |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
    |> Repo.insert!()
  end

  defp create_relationship(source, target, type \\ "knows") do
    relationship =
      %Relationship{}
      |> Relationship.changeset(%{source_id: source.id, target_id: target.id, type: type})
      |> Repo.insert!()

    chunk_id =
      Repo.one!(
        from(m in EntityMention,
          where: m.entity_id == ^source.id,
          order_by: m.inserted_at,
          limit: 1,
          select: m.chunk_id
        )
      )

    %RelationshipEvidence{}
    |> RelationshipEvidence.changeset(%{relationship_id: relationship.id, chunk_id: chunk_id})
    |> Repo.insert!()

    relationship
  end

  describe "query_depth/1" do
    test "defaults to 0" do
      assert Graph.query_depth([]) == 0
    end

    test "reads the per-call graph_depth option" do
      assert Graph.query_depth(graph_depth: 2) == 2
    end

    test "per-call option wins over global query_depth config" do
      put_arcana_env(:graph, query_depth: 3)

      assert Graph.query_depth([]) == 3
      assert Graph.query_depth(graph_depth: 1) == 1
      assert Graph.query_depth(graph_depth: 0) == 0
    end

    test "raises on invalid values" do
      assert_raise ArgumentError, fn -> Graph.query_depth(graph_depth: -1) end
      assert_raise ArgumentError, fn -> Graph.query_depth(graph_depth: "two") end
      assert_raise ArgumentError, fn -> Graph.query_depth(graph_depth: nil) end
    end

    test "graph_depth: false disables traversal even with a global default" do
      put_arcana_env(:graph, query_depth: 2)

      # matches the reranker: false disable idiom; previously fell
      # through || to the global config and silently traversed
      assert Graph.query_depth(graph_depth: false) == 0
    end
  end

  describe "expand_entity_ids/4" do
    setup do
      collection = create_collection("expand-test")
      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")
      carol = create_entity(collection, "Carol")
      create_relationship(alice, bob)
      create_relationship(bob, carol)

      %{collection: collection, alice: alice, bob: bob, carol: carol}
    end

    test "depth 0 returns only the input ids at hop 0", %{alice: alice} do
      assert Graph.expand_entity_ids([alice.id], 0, nil, repo: Repo) ==
               %{0 => [alice.id]}
    end

    test "depth 1 discovers one-hop neighbors", %{alice: alice, bob: bob} do
      assert Graph.expand_entity_ids([alice.id], 1, nil, repo: Repo) ==
               %{0 => [alice.id], 1 => [bob.id]}
    end

    test "depth 2 reaches two hops, each entity at its minimal hop", ctx do
      %{alice: alice, bob: bob, carol: carol} = ctx

      assert Graph.expand_entity_ids([alice.id], 2, nil, repo: Repo) ==
               %{0 => [alice.id], 1 => [bob.id], 2 => [carol.id]}
    end

    test "traverses edges in both directions", %{alice: alice, bob: bob, carol: carol} do
      expanded = Graph.expand_entity_ids([carol.id], 2, nil, repo: Repo)

      assert expanded[1] == [bob.id]
      assert expanded[2] == [alice.id]
    end

    test "does not revisit entities in cyclic graphs", ctx do
      %{alice: alice, bob: bob, carol: carol} = ctx
      create_relationship(carol, alice, "closes_cycle")

      expanded = Graph.expand_entity_ids([alice.id], 3, nil, repo: Repo)

      assert expanded[0] == [alice.id]
      assert Enum.sort(expanded[1]) == Enum.sort([bob.id, carol.id])
      refute Map.has_key?(expanded, 2)
    end

    test "collection scoping excludes neighbors from other collections", ctx do
      %{collection: collection, alice: alice, bob: bob} = ctx
      other = create_collection("expand-other")
      dave = create_entity(other, "Dave")
      create_relationship(alice, dave)

      expanded = Graph.expand_entity_ids([alice.id], 1, [collection.id], repo: Repo)
      assert expanded == %{0 => [alice.id], 1 => [bob.id]}

      unscoped = Graph.expand_entity_ids([alice.id], 1, nil, repo: Repo)
      assert Enum.sort(unscoped[1]) == Enum.sort([bob.id, dave.id])
    end

    test "empty collection list expands to nothing beyond hop 0", %{alice: alice} do
      assert Graph.expand_entity_ids([alice.id], 2, [], repo: Repo) ==
               %{0 => [alice.id]}
    end

    test "empty input returns empty map" do
      assert Graph.expand_entity_ids([], 2, nil, repo: Repo) == %{}
    end

    test "does not traverse through an entity supported only by a failed document", ctx do
      %{collection: collection, alice: alice} = ctx
      published_target = create_entity(collection, "Published target")

      failed_bridge =
        %Entity{}
        |> Entity.changeset(%{
          name: "Failed bridge",
          type: "person",
          collection_id: collection.id
        })
        |> Repo.insert!()

      add_evidence(failed_bridge, collection, :failed)
      create_relationship(alice, failed_bridge)
      create_relationship(failed_bridge, published_target)

      expanded = Graph.expand_entity_ids([alice.id], 2, nil, repo: Repo)

      refute failed_bridge.id in Map.get(expanded, 1, [])
      refute published_target.id in Map.get(expanded, 2, [])
    end
  end
end
