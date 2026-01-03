defmodule Arcana.Graph.GraphStore.EctoTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Graph.{Entity, EntityMention, Relationship}
  alias Arcana.Graph.GraphStore.Ecto, as: EctoStore

  defp create_collection(name \\ "test-collection") do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp create_document(collection, title \\ "test-doc") do
    %Document{}
    |> Document.changeset(%{
      title: title,
      source: "test",
      content: "Test document content",
      collection_id: collection.id,
      status: :completed
    })
    |> Repo.insert!()
  end

  defp create_chunk(document, text \\ "test content") do
    %Chunk{}
    |> Chunk.changeset(%{
      text: text,
      document_id: document.id,
      embedding: Enum.map(1..384, fn _ -> :rand.uniform() end)
    })
    |> Repo.insert!()
  end

  defp create_entity(collection, name, type \\ "person") do
    %Entity{}
    |> Entity.changeset(%{
      name: name,
      type: type,
      collection_id: collection.id
    })
    |> Repo.insert!()
  end

  defp create_mention(entity, chunk) do
    %EntityMention{}
    |> EntityMention.changeset(%{
      entity_id: entity.id,
      chunk_id: chunk.id
    })
    |> Repo.insert!()
  end

  describe "persist_entities/3" do
    test "inserts new entities and returns id map" do
      collection = create_collection()

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert map_size(id_map) == 2
      assert Map.has_key?(id_map, "Alice")
      assert Map.has_key?(id_map, "Bob")

      # Verify entities exist in DB
      assert Repo.get_by(Entity, name: "Alice", collection_id: collection.id)
      assert Repo.get_by(Entity, name: "Bob", collection_id: collection.id)
    end

    test "deduplicates entities by name" do
      collection = create_collection()

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Alice", type: "person"}
      ]

      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert map_size(id_map) == 1
    end

    test "returns existing entity ids on upsert" do
      collection = create_collection()
      existing = create_entity(collection, "Alice", "person")

      entities = [%{name: "Alice", type: "person"}]
      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert id_map["Alice"] == existing.id
    end
  end

  describe "persist_relationships/3" do
    test "inserts relationships between entities" do
      collection = create_collection()
      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")
      entity_id_map = %{"Alice" => alice.id, "Bob" => bob.id}

      relationships = [
        %{source: "Alice", target: "Bob", type: "knows"}
      ]

      assert :ok = EctoStore.persist_relationships(relationships, entity_id_map, repo: Repo)

      rel = Repo.get_by(Relationship, source_id: alice.id, target_id: bob.id)
      assert rel.type == "knows"
    end

    test "skips relationships with missing entities" do
      entity_id_map = %{"Alice" => Ecto.UUID.generate()}

      relationships = [
        %{source: "Alice", target: "Unknown", type: "knows"}
      ]

      assert :ok = EctoStore.persist_relationships(relationships, entity_id_map, repo: Repo)
      assert Repo.aggregate(Relationship, :count) == 0
    end
  end

  describe "persist_mentions/3" do
    test "inserts entity mentions linking to chunks" do
      collection = create_collection()
      document = create_document(collection)
      chunk = create_chunk(document)
      alice = create_entity(collection, "Alice")
      entity_id_map = %{"Alice" => alice.id}

      mentions = [
        %{entity_name: "Alice", chunk_id: chunk.id}
      ]

      assert :ok = EctoStore.persist_mentions(mentions, entity_id_map, repo: Repo)

      mention = Repo.get_by(EntityMention, entity_id: alice.id, chunk_id: chunk.id)
      assert mention
    end
  end

  describe "search/3" do
    test "finds chunks by entity names and scores by mention count" do
      collection = create_collection()
      document = create_document(collection)
      chunk1 = create_chunk(document, "Chunk with both")
      chunk2 = create_chunk(document, "Chunk with one")

      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")

      # chunk1 mentioned by both Alice and Bob (higher score)
      create_mention(alice, chunk1)
      create_mention(bob, chunk1)
      # chunk2 mentioned only by Alice
      create_mention(alice, chunk2)

      results = EctoStore.search(["Alice", "Bob"], [collection.id], repo: Repo)

      assert length(results) == 2
      # chunk1 should be first (higher score)
      [first, second] = results
      assert first.chunk_id == chunk1.id
      assert first.score > second.score
    end

    test "returns empty list when no entities match" do
      results = EctoStore.search(["Unknown"], nil, repo: Repo)
      assert results == []
    end
  end

  describe "find_entities/2" do
    test "returns all entities in collection" do
      collection = create_collection("test-find")
      other_collection = create_collection("other")

      create_entity(collection, "Alice", "person")
      create_entity(collection, "Bob", "person")
      create_entity(other_collection, "Other", "person")

      entities = EctoStore.find_entities(collection.id, repo: Repo)

      assert length(entities) == 2
      names = Enum.map(entities, & &1.name)
      assert "Alice" in names
      assert "Bob" in names
    end
  end
end
