defmodule Arcana.DocumentsTest do
  use Arcana.DataCase, async: true

  alias Arcana.Document

  describe "list_documents/1" do
    test "lists documents newest first with collection preloaded" do
      {:ok, _} = Arcana.ingest("First document", repo: Repo, collection: "docs-api")
      {:ok, _} = Arcana.ingest("Second document", repo: Repo, collection: "docs-api")

      {:ok, [newest, oldest]} = Arcana.list_documents(repo: Repo, collection: "docs-api")

      assert newest.inserted_at >= oldest.inserted_at
      assert newest.collection.name == "docs-api"
      assert newest.status == :completed
      assert newest.chunk_count > 0
    end

    test "filters by collection and matches nothing for unknown names" do
      {:ok, _} = Arcana.ingest("In collection A", repo: Repo, collection: "docs-a")
      {:ok, _} = Arcana.ingest("In collection B", repo: Repo, collection: "docs-b")

      {:ok, docs} = Arcana.list_documents(repo: Repo, collection: "docs-a")
      assert [%Document{}] = docs

      assert {:ok, []} = Arcana.list_documents(repo: Repo, collection: "docs-nope")
    end

    test "filters by status" do
      {:ok, _} = Arcana.ingest("Completed doc", repo: Repo, collection: "docs-status")

      {:ok, failed_doc} =
        %Document{}
        |> Document.changeset(%{content: "Failed doc", status: :failed})
        |> Repo.insert()

      {:ok, [only]} = Arcana.list_documents(repo: Repo, status: :failed)
      assert only.id == failed_doc.id

      {:ok, completed} = Arcana.list_documents(repo: Repo, status: :completed)
      refute Enum.any?(completed, &(&1.id == failed_doc.id))
    end

    test "filters by source_id" do
      {:ok, doc} = Arcana.ingest("Sourced doc", repo: Repo, source_id: "book-42")
      {:ok, _} = Arcana.ingest("Other doc", repo: Repo)

      assert {:ok, [%Document{id: id}]} = Arcana.list_documents(repo: Repo, source_id: "book-42")
      assert id == doc.id
    end

    test "paginates with limit and offset, count covers the full set" do
      for i <- 1..3 do
        {:ok, _} = Arcana.ingest("Paginated #{i}", repo: Repo, collection: "docs-page")
      end

      filters = [repo: Repo, collection: "docs-page"]

      {:ok, page1} = Arcana.list_documents(filters ++ [limit: 2, offset: 0])
      {:ok, page2} = Arcana.list_documents(filters ++ [limit: 2, offset: 2])

      assert length(page1) == 2
      assert length(page2) == 1
      assert Enum.uniq(Enum.map(page1 ++ page2, & &1.id)) |> length() == 3

      assert {:ok, 3} = Arcana.count_documents(filters)
    end
  end

  describe "get_document/2" do
    test "returns the document with collection preloaded" do
      {:ok, doc} = Arcana.ingest("Fetch me", repo: Repo, collection: "docs-get")

      assert {:ok, fetched} = Arcana.get_document(doc.id, repo: Repo)
      assert fetched.id == doc.id
      assert fetched.collection.name == "docs-get"
    end

    test "returns not_found for a missing id" do
      assert {:error, :not_found} = Arcana.get_document(Ecto.UUID.generate(), repo: Repo)
    end

    test "returns not_found for a malformed id instead of raising" do
      assert {:error, :not_found} = Arcana.get_document("not-a-uuid", repo: Repo)
    end
  end

  describe "list_documents/1 argument validation" do
    test "rejects negative or non-integer limit/offset" do
      assert_raise ArgumentError, ~r/must be a non-negative integer/, fn ->
        Arcana.list_documents(repo: Repo, limit: -1)
      end

      assert_raise ArgumentError, ~r/must be a non-negative integer/, fn ->
        Arcana.list_documents(repo: Repo, offset: "20")
      end
    end
  end
end
