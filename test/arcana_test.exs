defmodule ArcanaTest do
  use Arcana.DataCase, async: false

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
  end

  describe "search/2" do
    setup do
      # Ingest some documents for searching
      {:ok, doc1} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
      {:ok, doc2} = Arcana.ingest("Python is great for machine learning.", repo: Repo)
      {:ok, doc3} = Arcana.ingest("The weather today is sunny and warm.", repo: Repo)

      %{doc1: doc1, doc2: doc2, doc3: doc3}
    end

    test "finds relevant chunks", %{doc1: doc1} do
      results = Arcana.search("functional programming", repo: Repo)

      refute Enum.empty?(results)
      # First result should be from the Elixir document
      first = hd(results)
      assert first.document_id == doc1.id
      assert first.score > 0
    end

    test "respects limit option" do
      results = Arcana.search("programming", repo: Repo, limit: 2)

      assert length(results) <= 2
    end

    test "filters by source_id" do
      {:ok, _scoped_doc} =
        Arcana.ingest("Ruby programming language", repo: Repo, source_id: "scope-a")

      results = Arcana.search("programming", repo: Repo, source_id: "scope-a")

      refute Enum.empty?(results)

      assert Enum.all?(results, fn r ->
               doc = Repo.get!(Arcana.Document, r.document_id)
               doc.source_id == "scope-a"
             end)
    end
  end

  describe "delete/1" do
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
