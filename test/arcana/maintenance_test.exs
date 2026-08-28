defmodule Arcana.MaintenanceTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document, Maintenance}

  describe "rechunking crashed ingests" do
    test "recovered chunks carry the same metadata a fresh ingest would" do
      {:ok, collection} = Collection.get_or_create("default", Repo)

      {:ok, document} =
        %Document{}
        |> Document.changeset(%{
          content: "Alpha alpha alpha the first part. Bravo bravo bravo the second part.",
          status: :pending,
          chunk_count: 0,
          collection_id: collection.id
        })
        |> Repo.insert()

      assert {:ok, %{rechunked_documents: 1}} = Maintenance.reembed(Repo)

      chunks = Repo.all(from(c in Chunk, where: c.document_id == ^document.id))

      assert chunks != []

      for chunk <- chunks do
        assert is_integer(chunk.metadata["start_byte"])
        assert is_integer(chunk.metadata["end_byte"])
        assert chunk.metadata["end_byte"] > chunk.metadata["start_byte"]
      end
    end

    test "a custom chunker's extra keys survive rechunking too" do
      {:ok, collection} = Collection.get_or_create("default", Repo)

      {:ok, document} =
        %Document{}
        |> Document.changeset(%{
          content: "whatever",
          status: :pending,
          chunk_count: 0,
          collection_id: collection.id
        })
        |> Repo.insert()

      put_arcana_env(:chunker, fn text, _opts ->
        [
          %{
            text: text,
            chunk_index: 0,
            token_count: 2,
            page: 7,
            metadata: %{"section" => "intro"}
          }
        ]
      end)

      assert {:ok, %{rechunked_documents: 1}} = Maintenance.reembed(Repo)

      assert [chunk] = Repo.all(from(c in Chunk, where: c.document_id == ^document.id))
      assert chunk.metadata["page"] == 7
      assert chunk.metadata["section"] == "intro"
    end
  end

  describe "strict collections" do
    test "reembed/2 errors on an unknown collection" do
      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.reembed(Repo, collection: "strict-nope", strict_collections: true)
    end

    test "embed_entities/2 errors on an unknown collection instead of embedding globally" do
      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.embed_entities(Repo,
                 collection: "strict-nope",
                 strict_collections: true
               )
    end

    test "graph maintenance errors on an unknown collection instead of succeeding with zero work" do
      opts = [collection: "strict-nope", strict_collections: true]

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.rebuild_graph(Repo, opts)

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.detect_communities(Repo, opts)

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.summarize_communities(
                 Repo,
                 opts ++ [llm: fn _p, _c, _o -> {:ok, "summary"} end]
               )
    end

    test "graph maintenance reports zero work for unknown collections when strict is off" do
      assert {:ok, %{collections: 0}} = Maintenance.rebuild_graph(Repo, collection: "nope")
    end
  end

  describe "collection scopes" do
    test "graph maintenance accepts one or many collection names" do
      {:ok, _} = Collection.get_or_create("maintenance-a", Repo)
      {:ok, _} = Collection.get_or_create("maintenance-b", Repo)
      {:ok, _} = Collection.get_or_create("maintenance-outside", Repo)

      assert {:ok, %{collections: 1}} =
               Maintenance.rebuild_graph(Repo, collection: "maintenance-a")

      assert {:ok, %{collections: 2}} =
               Maintenance.rebuild_graph(Repo,
                 collection: ["maintenance-a", "maintenance-b", "missing"]
               )
    end

    test "empty and unknown scopes never widen re-embedding to every collection" do
      {:ok, collection} = Collection.get_or_create("maintenance-existing", Repo)

      document =
        %Document{}
        |> Document.changeset(%{
          content: "must remain untouched",
          status: :pending,
          chunk_count: 0,
          collection_id: collection.id
        })
        |> Repo.insert!()

      assert {:ok, %{rechunked_documents: 0, total_chunks: 0}} =
               Maintenance.reembed(Repo, collection: [])

      assert {:ok, %{rechunked_documents: 0, total_chunks: 0}} =
               Maintenance.reembed(Repo, collection: "missing")

      assert Repo.get!(Document, document.id).chunk_count == 0
      assert Repo.aggregate(Chunk, :count) == 0
    end

    test "malformed and removed collection scopes are rejected" do
      assert {:error, {:invalid_collection_scope, ["a", nil]}} =
               Maintenance.rebuild_graph(Repo, collection: ["a", nil])

      assert {:error, {:unsupported_collection_option, :collections}} =
               Maintenance.rebuild_graph(Repo, collections: ["a"])
    end
  end
end
