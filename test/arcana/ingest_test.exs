defmodule Arcana.IngestTest do
  use Arcana.DataCase, async: true

  describe "ingest/2" do
    test "creates document and chunks from text" do
      text = "This is a test document. It has some content that will be chunked and embedded."

      {:ok, document} = Arcana.ingest(text, repo: Repo)

      assert document.id
      assert document.content == text
      assert document.status == :completed
      assert document.chunk_count > 0

      chunks = Repo.all(Arcana.Chunk)
      assert length(chunks) == document.chunk_count
      assert Enum.all?(chunks, fn c -> c.document_id == document.id end)
    end

    test "accepts source_id option" do
      {:ok, document} = Arcana.ingest("test", repo: Repo, source_id: "my-doc-123")

      assert document.source_id == "my-doc-123"
    end

    test "accepts metadata option" do
      metadata = %{"author" => "Jane", "category" => "tech"}

      {:ok, document} = Arcana.ingest("test", repo: Repo, metadata: metadata)

      assert document.metadata == metadata
    end

    test "accepts collection as string" do
      {:ok, document} = Arcana.ingest("test", repo: Repo, collection: "my-collection")

      collection = Repo.get!(Arcana.Collection, document.collection_id)
      assert collection.name == "my-collection"
    end

    test "accepts collection as map with name and description" do
      {:ok, document} =
        Arcana.ingest("test",
          repo: Repo,
          collection: %{name: "docs", description: "Official documentation"}
        )

      collection = Repo.get!(Arcana.Collection, document.collection_id)
      assert collection.name == "docs"
      assert collection.description == "Official documentation"
    end

    test "updates collection description if already exists" do
      # First, create the collection without description
      {:ok, doc1} = Arcana.ingest("first doc", repo: Repo, collection: "existing")

      collection1 = Repo.get!(Arcana.Collection, doc1.collection_id)
      assert collection1.description == nil

      # Now ingest with description - should update
      {:ok, doc2} =
        Arcana.ingest("second doc",
          repo: Repo,
          collection: %{name: "existing", description: "Now with description"}
        )

      collection2 = Repo.get!(Arcana.Collection, doc2.collection_id)
      assert collection2.id == collection1.id
      assert collection2.description == "Now with description"
    end
  end

  describe "delete/2" do
    test "deletes document and its chunks" do
      {:ok, document} = Arcana.ingest("Test document to delete", repo: Repo)
      chunk_count = Repo.aggregate(Arcana.Chunk, :count)
      assert chunk_count > 0

      :ok = Arcana.delete(document.id, repo: Repo)

      assert Repo.get(Arcana.Document, document.id) == nil
      assert Repo.aggregate(Arcana.Chunk, :count) == 0
    end

    test "returns error for non-existent document" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} = Arcana.delete(fake_id, repo: Repo)
    end
  end
end
