defmodule Arcana.ChunkTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Document}
  alias Arcana.Embeddings.Serving

  describe "changeset/2" do
    test "valid with required fields" do
      embedding = Serving.embed("test")
      changeset = Chunk.changeset(%Chunk{}, %{text: "Hello", embedding: embedding})

      assert changeset.valid?
    end

    test "invalid without text" do
      embedding = Serving.embed("test")
      changeset = Chunk.changeset(%Chunk{}, %{embedding: embedding})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).text
    end

    test "invalid without embedding" do
      changeset = Chunk.changeset(%Chunk{}, %{text: "Hello"})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).embedding
    end
  end

  describe "database operations" do
    test "inserts chunk with document association" do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{content: "Full document"})
        |> Repo.insert()

      embedding = Serving.embed("chunk text")

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "chunk text",
          embedding: embedding,
          document_id: doc.id,
          chunk_index: 0
        })
        |> Repo.insert()

      assert chunk.id
      assert chunk.document_id == doc.id
      assert Pgvector.to_list(chunk.embedding) |> length() == 32
    end

    test "deletes chunks when document is deleted" do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{content: "Test"})
        |> Repo.insert()

      embedding = Serving.embed("chunk")

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{text: "chunk", embedding: embedding, document_id: doc.id})
        |> Repo.insert()

      Repo.delete!(doc)

      assert Repo.all(Chunk) == []
    end
  end
end
