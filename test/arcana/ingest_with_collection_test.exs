defmodule Arcana.IngestWithCollectionTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection

  describe "ingest/2 with collection" do
    test "ingests document into default collection when no collection specified" do
      {:ok, document} = Arcana.ingest("Test content", repo: Arcana.TestRepo)

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection.name == "default"
    end

    test "ingests document into specified collection by name" do
      {:ok, document} =
        Arcana.ingest("Test content", repo: Arcana.TestRepo, collection: "products")

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection.name == "products"
    end

    test "ingests document into existing collection" do
      {:ok, collection} =
        %Collection{}
        |> Collection.changeset(%{name: "existing-collection"})
        |> Arcana.TestRepo.insert()

      {:ok, document} =
        Arcana.ingest("Test content", repo: Arcana.TestRepo, collection: "existing-collection")

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection_id == collection.id
    end

    test "creates collection if it doesn't exist" do
      {:ok, document} =
        Arcana.ingest("Test content", repo: Arcana.TestRepo, collection: "new-collection")

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection.name == "new-collection"
    end
  end

  describe "ingest_file/2 with collection" do
    test "ingests file into specified collection" do
      path = create_temp_file("File content", ".txt")

      {:ok, document} =
        Arcana.ingest_file(path, repo: Arcana.TestRepo, collection: "file-collection")

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection.name == "file-collection"
    end

    test "defaults to default collection for files" do
      path = create_temp_file("File content", ".txt")

      {:ok, document} = Arcana.ingest_file(path, repo: Arcana.TestRepo)

      document = Arcana.TestRepo.preload(document, :collection)
      assert document.collection.name == "default"
    end
  end

  describe "search/2 with collection filter" do
    test "filters search results by collection" do
      {:ok, _} = Arcana.ingest("Elixir programming", repo: Arcana.TestRepo, collection: "docs")
      {:ok, _} = Arcana.ingest("Elixir syntax", repo: Arcana.TestRepo, collection: "tutorials")

      {:ok, docs_results} = Arcana.search("Elixir", repo: Arcana.TestRepo, collection: "docs")
      {:ok, tutorials_results} = Arcana.search("Elixir", repo: Arcana.TestRepo, collection: "tutorials")

      assert length(docs_results) == 1
      assert length(tutorials_results) == 1
    end

    test "returns all results when no collection filter" do
      {:ok, _} = Arcana.ingest("Elixir programming", repo: Arcana.TestRepo, collection: "docs")
      {:ok, _} = Arcana.ingest("Elixir syntax", repo: Arcana.TestRepo, collection: "tutorials")

      {:ok, results} = Arcana.search("Elixir", repo: Arcana.TestRepo)

      assert length(results) == 2
    end
  end

  defp create_temp_file(content, extension) do
    dir = System.tmp_dir!()
    filename = "arcana_test_#{:rand.uniform(100_000)}#{extension}"
    path = Path.join(dir, filename)
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
