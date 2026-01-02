defmodule Arcana.ChunkTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Document}

  # Static test embedding (384 dimensions matching production default)
  defp test_embedding, do: List.duplicate(0.5, 384)

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Chunk.changeset(%Chunk{}, %{text: "Hello", embedding: test_embedding()})

      assert changeset.valid?
    end

    test "invalid without text" do
      changeset = Chunk.changeset(%Chunk{}, %{embedding: test_embedding()})

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

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "chunk text",
          embedding: test_embedding(),
          document_id: doc.id,
          chunk_index: 0
        })
        |> Repo.insert()

      assert chunk.id
      assert chunk.document_id == doc.id
      assert Pgvector.to_list(chunk.embedding) |> length() == 384
    end

    test "deletes chunks when document is deleted" do
      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{content: "Test"})
        |> Repo.insert()

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{text: "chunk", embedding: test_embedding(), document_id: doc.id})
        |> Repo.insert()

      Repo.delete!(doc)

      assert Repo.all(Chunk) == []
    end
  end
end
