defmodule Arcana.VectorStore.PgvectorTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.VectorStore.Pgvector

  describe "search/3" do
    test "finds stored vectors" do
      repo = Arcana.TestRepo

      # Create collection and document
      {:ok, collection} = Collection.get_or_create("test-collection", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test content",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      # Create chunks with embeddings - make them similar enough to both be found
      embedding1 = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      embedding2 = normalize([0.8, 0.2, 0.0] ++ List.duplicate(0.0, 381))

      {:ok, _chunk1} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "first chunk",
          embedding: embedding1,
          metadata: %{position: "first"},
          document_id: doc.id
        })
        |> repo.insert()

      {:ok, _chunk2} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "second chunk",
          embedding: embedding2,
          metadata: %{position: "second"},
          document_id: doc.id
        })
        |> repo.insert()

      # Search with query similar to embedding1
      query = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      results = Pgvector.search("test-collection", query, repo: repo, limit: 10)

      assert length(results) == 2
      # First result should be most similar to query
      first = hd(results)
      assert first.metadata[:text] == "first chunk"
      assert first.score > 0.9
    end

    test "respects limit option" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("limit-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      # Create 5 chunks
      for i <- 1..5 do
        embedding = normalize([i / 10.0] ++ List.duplicate(0.0, 383))

        %Chunk{}
        |> Chunk.changeset(%{
          text: "chunk #{i}",
          embedding: embedding,
          document_id: doc.id
        })
        |> repo.insert!()
      end

      query = normalize([0.5] ++ List.duplicate(0.0, 383))
      results = Pgvector.search("limit-test", query, repo: repo, limit: 3)

      assert length(results) == 3
    end

    test "filters by collection" do
      repo = Arcana.TestRepo

      {:ok, coll1} = Collection.get_or_create("collection-a", repo)
      {:ok, coll2} = Collection.get_or_create("collection-b", repo)

      embedding = normalize([1.0] ++ List.duplicate(0.0, 383))

      {:ok, doc1} =
        %Document{}
        |> Document.changeset(%{
          content: "doc a",
          status: :completed,
          collection_id: coll1.id
        })
        |> repo.insert()

      {:ok, doc2} =
        %Document{}
        |> Document.changeset(%{
          content: "doc b",
          status: :completed,
          collection_id: coll2.id
        })
        |> repo.insert()

      %Chunk{}
      |> Chunk.changeset(%{
        text: "chunk in a",
        embedding: embedding,
        document_id: doc1.id
      })
      |> repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{
        text: "chunk in b",
        embedding: embedding,
        document_id: doc2.id
      })
      |> repo.insert!()

      results_a = Pgvector.search("collection-a", embedding, repo: repo, limit: 10)
      results_b = Pgvector.search("collection-b", embedding, repo: repo, limit: 10)

      assert length(results_a) == 1
      assert hd(results_a).metadata[:text] == "chunk in a"

      assert length(results_b) == 1
      assert hd(results_b).metadata[:text] == "chunk in b"
    end

    test "returns empty list for empty collection" do
      repo = Arcana.TestRepo

      {:ok, _collection} = Collection.get_or_create("empty-collection", repo)

      query = List.duplicate(0.5, 384)
      results = Pgvector.search("empty-collection", query, repo: repo, limit: 10)

      assert results == []
    end
  end

  describe "delete/3" do
    test "removes chunk from collection" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("delete-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      embedding = List.duplicate(0.5, 384)

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "to delete",
          embedding: embedding,
          document_id: doc.id
        })
        |> repo.insert()

      assert :ok = Pgvector.delete("delete-test", chunk.id, repo: repo)

      # Verify it's gone
      assert repo.get(Chunk, chunk.id) == nil
    end

    test "returns error for non-existent id" do
      repo = Arcana.TestRepo

      fake_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Pgvector.delete("any", fake_id, repo: repo)
    end
  end

  describe "clear/2" do
    test "removes all chunks in collection" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("clear-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      embedding = List.duplicate(0.5, 384)

      for i <- 1..3 do
        %Chunk{}
        |> Chunk.changeset(%{
          text: "chunk #{i}",
          embedding: embedding,
          document_id: doc.id
        })
        |> repo.insert!()
      end

      assert :ok = Pgvector.clear("clear-test", repo: repo)

      # Verify collection is empty
      results = Pgvector.search("clear-test", embedding, repo: repo, limit: 10)
      assert results == []
    end

    test "only clears specified collection" do
      repo = Arcana.TestRepo

      {:ok, coll1} = Collection.get_or_create("clear-a", repo)
      {:ok, coll2} = Collection.get_or_create("clear-b", repo)

      embedding = List.duplicate(0.5, 384)

      {:ok, doc1} =
        %Document{}
        |> Document.changeset(%{
          content: "a",
          status: :completed,
          collection_id: coll1.id
        })
        |> repo.insert()

      {:ok, doc2} =
        %Document{}
        |> Document.changeset(%{
          content: "b",
          status: :completed,
          collection_id: coll2.id
        })
        |> repo.insert()

      %Chunk{}
      |> Chunk.changeset(%{text: "a chunk", embedding: embedding, document_id: doc1.id})
      |> repo.insert!()

      %Chunk{}
      |> Chunk.changeset(%{text: "b chunk", embedding: embedding, document_id: doc2.id})
      |> repo.insert!()

      assert :ok = Pgvector.clear("clear-a", repo: repo)

      assert [] = Pgvector.search("clear-a", embedding, repo: repo, limit: 10)

      results_b = Pgvector.search("clear-b", embedding, repo: repo, limit: 10)
      assert length(results_b) == 1
    end
  end

  describe "search_hybrid/4" do
    test "combines semantic and fulltext scores in single query" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("hybrid-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test content",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      # Create chunks with embeddings and searchable text
      embedding1 = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      embedding2 = normalize([0.8, 0.2, 0.0] ++ List.duplicate(0.0, 381))

      {:ok, _chunk1} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "Elixir is a functional programming language",
          embedding: embedding1,
          document_id: doc.id
        })
        |> repo.insert()

      {:ok, _chunk2} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "Phoenix is a web framework for Elixir",
          embedding: embedding2,
          document_id: doc.id
        })
        |> repo.insert()

      query_embedding = normalize([0.9, 0.1, 0.0] ++ List.duplicate(0.0, 381))

      results =
        Pgvector.search_hybrid(
          "hybrid-test",
          query_embedding,
          "Elixir",
          repo: repo, limit: 10
        )

      assert length(results) == 2

      # Results should have combined scores
      first = hd(results)
      assert first.score > 0
      assert first.metadata[:semantic_score] > 0
      assert first.metadata[:fulltext_score] >= 0
    end

    test "respects weight options" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("weight-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      embedding = normalize([1.0] ++ List.duplicate(0.0, 383))

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "test content with keywords",
          embedding: embedding,
          document_id: doc.id
        })
        |> repo.insert()

      # Test with different weight configurations
      semantic_heavy =
        Pgvector.search_hybrid(
          "weight-test",
          embedding,
          "test",
          repo: repo, semantic_weight: 0.9, fulltext_weight: 0.1
        )

      fulltext_heavy =
        Pgvector.search_hybrid(
          "weight-test",
          embedding,
          "test",
          repo: repo, semantic_weight: 0.1, fulltext_weight: 0.9
        )

      assert length(semantic_heavy) == 1
      assert length(fulltext_heavy) == 1

      # Scores should differ based on weights
      # (both will return same chunk but with different combined scores)
      semantic_result = hd(semantic_heavy)
      fulltext_result = hd(fulltext_heavy)

      # Both should have the individual scores
      assert semantic_result.metadata[:semantic_score] > 0
      assert fulltext_result.metadata[:semantic_score] > 0
    end

    test "respects threshold option" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("threshold-hybrid-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      # Create chunk with low-similarity embedding
      embedding = normalize([0.1] ++ List.duplicate(0.0, 383))
      query = normalize([1.0] ++ List.duplicate(0.0, 383))

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "unrelated content",
          embedding: embedding,
          document_id: doc.id
        })
        |> repo.insert()

      # With high threshold, should filter out low-scoring results
      results =
        Pgvector.search_hybrid(
          "threshold-hybrid-test",
          query,
          "unrelated",
          repo: repo, threshold: 0.9
        )

      # Combined score unlikely to exceed 0.9 threshold
      assert results == []

      # With low threshold, should return results
      results_low =
        Pgvector.search_hybrid(
          "threshold-hybrid-test",
          query,
          "unrelated",
          repo: repo, threshold: 0.0
        )

      assert length(results_low) == 1
    end
  end

  # Helper to normalize a vector to unit length
  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, fn x, sum -> sum + x * x end))

    if magnitude > 0 do
      Enum.map(vector, &(&1 / magnitude))
    else
      vector
    end
  end
end
