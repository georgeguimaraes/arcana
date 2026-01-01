defmodule Arcana.Graph.EntityMentionTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Embeddings.Serving
  alias Arcana.Graph.{Entity, EntityMention}

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        EntityMention.changeset(%EntityMention{}, %{
          entity_id: Ecto.UUID.generate(),
          chunk_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "valid with all fields" do
      changeset =
        EntityMention.changeset(%EntityMention{}, %{
          entity_id: Ecto.UUID.generate(),
          chunk_id: Ecto.UUID.generate(),
          span_start: 10,
          span_end: 16,
          context: "...founded by OpenAI in 2015..."
        })

      assert changeset.valid?
    end

    test "invalid without entity_id" do
      changeset =
        EntityMention.changeset(%EntityMention{}, %{
          chunk_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).entity_id
    end

    test "invalid without chunk_id" do
      changeset =
        EntityMention.changeset(%EntityMention{}, %{
          entity_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).chunk_id
    end
  end

  describe "database operations" do
    test "inserts mention linking entity to chunk" do
      {:ok, collection} = create_collection()
      {:ok, doc} = create_document(collection)
      {:ok, chunk} = create_chunk(doc, "OpenAI released GPT-4")
      {:ok, entity} = create_entity("OpenAI", :organization)

      {:ok, mention} =
        %EntityMention{}
        |> EntityMention.changeset(%{
          entity_id: entity.id,
          chunk_id: chunk.id,
          span_start: 0,
          span_end: 6,
          context: "OpenAI released GPT-4"
        })
        |> Repo.insert()

      assert mention.id
      assert mention.entity_id == entity.id
      assert mention.chunk_id == chunk.id
      assert mention.span_start == 0
      assert mention.span_end == 6
    end

    test "loads entity and chunk associations" do
      {:ok, collection} = create_collection()
      {:ok, doc} = create_document(collection)
      {:ok, chunk} = create_chunk(doc, "OpenAI released GPT-4")
      {:ok, entity} = create_entity("OpenAI", :organization)

      {:ok, mention} =
        %EntityMention{}
        |> EntityMention.changeset(%{
          entity_id: entity.id,
          chunk_id: chunk.id
        })
        |> Repo.insert()

      mention = Repo.preload(mention, [:entity, :chunk])

      assert mention.entity.name == "OpenAI"
      assert mention.chunk.text == "OpenAI released GPT-4"
    end

    test "deletes mentions when entity is deleted" do
      {:ok, collection} = create_collection()
      {:ok, doc} = create_document(collection)
      {:ok, chunk} = create_chunk(doc, "OpenAI released GPT-4")
      {:ok, entity} = create_entity("OpenAI", :organization)

      {:ok, _mention} =
        %EntityMention{}
        |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
        |> Repo.insert()

      Repo.delete!(entity)

      assert Repo.all(EntityMention) == []
    end

    test "deletes mentions when chunk is deleted" do
      {:ok, collection} = create_collection()
      {:ok, doc} = create_document(collection)
      {:ok, chunk} = create_chunk(doc, "OpenAI released GPT-4")
      {:ok, entity} = create_entity("OpenAI", :organization)

      {:ok, _mention} =
        %EntityMention{}
        |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
        |> Repo.insert()

      Repo.delete!(chunk)

      assert Repo.all(EntityMention) == []
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

  defp create_chunk(document, text) do
    embedding = Serving.embed(text)

    %Chunk{}
    |> Chunk.changeset(%{text: text, embedding: embedding, document_id: document.id})
    |> Repo.insert()
  end

  defp create_entity(name, type) do
    %Entity{}
    |> Entity.changeset(%{name: name, type: type})
    |> Repo.insert()
  end
end
