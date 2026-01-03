defmodule Arcana.Graph.EntityTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Graph.Entity

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Entity.changeset(%Entity{}, %{name: "OpenAI", type: "organization"})

      assert changeset.valid?
    end

    test "valid with all fields" do
      {:ok, embedding} = embed("OpenAI")

      changeset =
        Entity.changeset(%Entity{}, %{
          name: "OpenAI",
          type: "organization",
          description: "AI research company",
          embedding: embedding,
          metadata: %{"founded" => "2015"}
        })

      assert changeset.valid?
    end

    test "invalid without name" do
      changeset = Entity.changeset(%Entity{}, %{type: "organization"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "invalid without type" do
      changeset = Entity.changeset(%Entity{}, %{name: "OpenAI"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).type
    end

    test "invalid with unknown type" do
      changeset = Entity.changeset(%Entity{}, %{name: "OpenAI", type: :unknown_type})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).type
    end
  end

  describe "entity types" do
    test "accepts all valid entity types" do
      valid_types = [
        "person",
        "organization",
        "location",
        "event",
        "concept",
        "technology",
        "other"
      ]

      for type <- valid_types do
        changeset = Entity.changeset(%Entity{}, %{name: "Test", type: type})
        assert changeset.valid?, "Expected type #{type} to be valid"
      end
    end
  end

  describe "database operations" do
    test "inserts entity with chunk association" do
      {:ok, collection} = create_collection()
      {:ok, doc} = create_document(collection)
      {:ok, chunk} = create_chunk(doc)

      {:ok, entity} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          description: "AI research company",
          chunk_id: chunk.id,
          collection_id: collection.id
        })
        |> Repo.insert()

      assert entity.id
      assert entity.name == "OpenAI"
      assert entity.type == "organization"
      assert entity.chunk_id == chunk.id
      assert entity.collection_id == collection.id
    end

    test "inserts entity with embedding" do
      {:ok, embedding} = embed("OpenAI AI research")

      {:ok, entity} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          embedding: embedding
        })
        |> Repo.insert()

      assert Pgvector.to_list(entity.embedding) |> length() == 384
    end

    test "enforces unique name per collection" do
      {:ok, collection} = create_collection()

      {:ok, _} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:error, changeset} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection.id
        })
        |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end

    test "allows same name in different collections" do
      {:ok, collection1} = create_collection("collection1")
      {:ok, collection2} = create_collection("collection2")

      {:ok, entity1} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection1.id
        })
        |> Repo.insert()

      {:ok, entity2} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection2.id
        })
        |> Repo.insert()

      assert entity1.id != entity2.id
    end
  end

  defp create_collection(name \\ "test-collection") do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert()
  end

  defp create_document(collection) do
    %Document{}
    |> Document.changeset(%{content: "Test document", collection_id: collection.id})
    |> Repo.insert()
  end

  defp create_chunk(document) do
    {:ok, embedding} = embed("chunk text")

    %Chunk{}
    |> Chunk.changeset(%{text: "chunk text", embedding: embedding, document_id: document.id})
    |> Repo.insert()
  end

  defp embed(text) do
    embedder = Application.get_env(:arcana, :embedder)
    embedder.(text)
  end
end
