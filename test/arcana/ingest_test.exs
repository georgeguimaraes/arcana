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

  describe "ingest/2 with replace: true" do
    test "re-ingesting the same identity replaces the document and its chunks" do
      {:ok, old} = Arcana.ingest("old text", repo: Repo, source_id: "doc-1", replace: true)
      {:ok, new} = Arcana.ingest("new text", repo: Repo, source_id: "doc-1", replace: true)

      assert old.id != new.id
      assert Repo.get(Arcana.Document, old.id) == nil

      assert [document] = Repo.all(Arcana.Document)
      assert document.id == new.id
      assert document.content == "new text"
      assert document.status == :completed

      # the replaced document's chunks cascaded away with it
      chunks = Repo.all(Arcana.Chunk)
      assert Enum.all?(chunks, fn c -> c.document_id == new.id end)
    end

    test "only replaces within the same (collection, source_id) identity" do
      {:ok, other_source} = Arcana.ingest("keep me", repo: Repo, source_id: "doc-2")

      {:ok, other_collection} =
        Arcana.ingest("keep me too", repo: Repo, source_id: "doc-1", collection: "other")

      {:ok, _v1} = Arcana.ingest("v1", repo: Repo, source_id: "doc-1", replace: true)
      {:ok, v2} = Arcana.ingest("v2", repo: Repo, source_id: "doc-1", replace: true)

      surviving_ids = Repo.all(Arcana.Document) |> Enum.map(& &1.id) |> Enum.sort()
      assert surviving_ids == Enum.sort([other_source.id, other_collection.id, v2.id])
    end

    test "sweeps failed and processing leftovers from crashed prior attempts" do
      {:ok, collection} = Arcana.Collection.get_or_create("default", Repo)

      for status <- [:failed, :processing] do
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "crashed attempt",
          source_id: "doc-1",
          status: status,
          collection_id: collection.id
        })
        |> Repo.insert!()
      end

      {:ok, document} = Arcana.ingest("recovered", repo: Repo, source_id: "doc-1", replace: true)

      assert [%{id: id, status: :completed}] = Repo.all(Arcana.Document)
      assert id == document.id
    end

    test "without replace, documents for the same identity accumulate (unchanged behavior)" do
      {:ok, _} = Arcana.ingest("v1", repo: Repo, source_id: "doc-1")
      {:ok, _} = Arcana.ingest("v2", repo: Repo, source_id: "doc-1")

      assert Repo.aggregate(Arcana.Document, :count) == 2
    end

    test "requires a source_id identity" do
      assert_raise ArgumentError, ~r/requires a :source_id/, fn ->
        Arcana.ingest("text", repo: Repo, replace: true)
      end
    end
  end
end
