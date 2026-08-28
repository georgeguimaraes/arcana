defmodule Arcana.DocumentsTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Document, DocumentMetadata, TestRepo}
  alias Ecto.Adapters.SQL

  defmodule QueryCapturingRepo do
    @moduledoc false

    def all(query) do
      {sql, _params} = SQL.to_sql(:all, TestRepo, query)
      send(self(), {:documents_query, sql})
      TestRepo.all(query)
    end
  end

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

    test "supports all, none, one, and many collection scopes" do
      {:ok, first} = Arcana.ingest("In scope A", repo: Repo, collection: "scope-a")
      {:ok, second} = Arcana.ingest("In scope B", repo: Repo, collection: "scope-b")
      {:ok, outside} = Arcana.ingest("Outside", repo: Repo, collection: "scope-c")

      assert {:ok, one} = Arcana.list_documents(repo: Repo, collection: "scope-a")
      assert [%Document{id: first_id}] = one
      assert first_id == first.id

      assert {:ok, many} =
               Arcana.list_documents(repo: Repo, collections: ["scope-a", "scope-b"])

      assert MapSet.new(Enum.map(many, & &1.id)) == MapSet.new([first.id, second.id])
      refute Enum.any?(many, &(&1.id == outside.id))

      assert {:ok, []} = Arcana.list_documents(repo: Repo, collections: [])
      assert {:ok, 0} = Arcana.count_documents(repo: Repo, collections: [])

      assert {:ok, all} = Arcana.list_documents(repo: Repo, collection: :all)
      assert Enum.all?([first, second, outside], fn doc -> Enum.any?(all, &(&1.id == doc.id)) end)
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

    test "applies collection scope in the document lookup" do
      {:ok, doc} = Arcana.ingest("Scoped fetch", repo: Repo, collection: "get-scope")

      assert {:ok, %Document{id: id}} =
               Arcana.get_document(doc.id, repo: Repo, collection: "get-scope")

      assert id == doc.id

      assert {:error, :not_found} =
               Arcana.get_document(doc.id, repo: Repo, collections: ["somewhere-else"])

      assert {:error, :not_found} = Arcana.get_document(doc.id, repo: Repo, collections: [])
    end
  end

  describe "get_document_metadata/2" do
    test "returns a sparse ID-keyed projection in one query and deduplicates IDs" do
      {:ok, doc} =
        Arcana.ingest("Large original content that must stay out of the select",
          repo: Repo,
          collection: "metadata-api",
          source_id: "guide-7",
          metadata: %{"title" => "Guide"}
        )

      id = doc.id

      assert {:ok, %{^id => metadata}} =
               Arcana.get_document_metadata([doc.id, doc.id],
                 repo: QueryCapturingRepo,
                 collection: "metadata-api"
               )

      assert %DocumentMetadata{
               id: doc.id,
               source_id: "guide-7",
               metadata: %{"title" => "Guide"}
             } == metadata

      assert %{id: doc.id, source_id: "guide-7", metadata: %{"title" => "Guide"}} ==
               DocumentMetadata.to_map(metadata)

      assert_receive {:documents_query, sql}
      refute_receive {:documents_query, _sql}
      assert sql =~ ~s("source_id")
      assert sql =~ ~s("metadata")
      refute sql =~ ~s(."content")
    end

    test "returns only completed documents inside the explicit scope" do
      {:ok, included} =
        Arcana.ingest("Included", repo: Repo, collection: "metadata-in", source_id: "in")

      {:ok, outside} =
        Arcana.ingest("Outside", repo: Repo, collection: "metadata-out", source_id: "out")

      {:ok, collection} = Arcana.Collection.get_or_create("metadata-in", Repo)

      {:ok, pending} =
        %Document{}
        |> Document.changeset(%{
          content: "Pending",
          status: :pending,
          source_id: "pending",
          collection_id: collection.id
        })
        |> Repo.insert()

      missing = Ecto.UUID.generate()

      assert {:ok, result} =
               Arcana.get_document_metadata([included.id, outside.id, pending.id, missing],
                 repo: Repo,
                 collections: ["metadata-in"]
               )

      included_id = included.id
      assert %{^included_id => %DocumentMetadata{source_id: "in"}} = result
      refute Map.has_key?(result, outside.id)
      refute Map.has_key?(result, pending.id)
      refute Map.has_key?(result, missing)
    end

    test "requires an explicit scope and accepts explicit all or none" do
      {:ok, doc} = Arcana.ingest("All scope", repo: Repo, collection: "metadata-all")
      id = doc.id

      assert_raise ArgumentError, ~r/requires an explicit/, fn ->
        Arcana.get_document_metadata([doc.id], repo: Repo)
      end

      assert {:ok, %{^id => %DocumentMetadata{}}} =
               Arcana.get_document_metadata([doc.id], repo: Repo, collection: :all)

      assert {:ok, %{}} =
               Arcana.get_document_metadata([doc.id], repo: Repo, collections: [])
    end

    test "does not query for an empty ID list" do
      assert {:ok, %{}} =
               Arcana.get_document_metadata([], repo: QueryCapturingRepo, collection: :all)

      refute_receive {:documents_query, _sql}
    end

    test "rejects malformed IDs before querying" do
      assert {:error, {:invalid_document_id, "not-a-uuid"}} =
               Arcana.get_document_metadata([Ecto.UUID.generate(), "not-a-uuid"],
                 repo: QueryCapturingRepo,
                 collection: :all
               )

      refute_receive {:documents_query, _sql}
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
