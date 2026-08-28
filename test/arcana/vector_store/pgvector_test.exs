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

    test "only completed documents are visible through every retrieval mode" do
      repo = Arcana.TestRepo
      {:ok, collection} = Collection.get_or_create("published-only", repo)
      embedding = normalize([1.0] ++ List.duplicate(0.0, 383))

      candidates =
        for status <- [:completed, :processing, :failed], into: %{} do
          document =
            %Document{}
            |> Document.changeset(%{
              content: "publication invariant",
              status: status,
              collection_id: collection.id
            })
            |> repo.insert!()

          chunk =
            %Chunk{}
            |> Chunk.changeset(%{
              text: "publication invariant #{status}",
              embedding: embedding,
              document_id: document.id
            })
            |> repo.insert!()

          {status, %{document: document, chunk: chunk}}
        end

      searches = [
        vector: fn ->
          Pgvector.search("published-only", embedding,
            repo: repo,
            limit: 10,
            threshold: -1.0
          )
        end,
        keyword: fn ->
          Pgvector.search_text("published-only", "publication invariant", repo: repo, limit: 10)
        end,
        hybrid: fn ->
          Pgvector.search_hybrid(
            "published-only",
            embedding,
            "publication invariant",
            repo: repo,
            limit: 10,
            threshold: -1.0
          )
        end
      ]

      for {mode, search} <- searches do
        results = search.()
        document_ids = Enum.map(results, &normalize_uuid(&1.metadata.document_id))
        chunk_ids = Enum.map(results, &normalize_uuid(&1.id))

        assert document_ids == [candidates.completed.document.id],
               "#{mode} exposed a document that has not been published"

        refute candidates.processing.chunk.id in chunk_ids
        refute candidates.failed.chunk.id in chunk_ids
      end
    end

    test "search_text handles tsquery special characters safely" do
      repo = Arcana.TestRepo

      {:ok, _collection} = Collection.get_or_create("tsquery-test", repo)

      # These should not crash - tsquery operators are sanitized
      assert [] = Pgvector.search_text("tsquery-test", "foo | bar", repo: repo)
      assert [] = Pgvector.search_text("tsquery-test", "foo & bar", repo: repo)
      assert [] = Pgvector.search_text("tsquery-test", "!foo", repo: repo)
      assert [] = Pgvector.search_text("tsquery-test", "foo:*", repo: repo)
      assert [] = Pgvector.search_text("tsquery-test", "(foo)", repo: repo)
    end
  end

  describe "store/5 with strict collections" do
    test "errors instead of auto-creating an unknown collection" do
      repo = Arcana.TestRepo
      embedding = List.duplicate(0.5, 384)

      assert {:error, {:unknown_collection, "strict-store-nope"}} =
               Pgvector.store("strict-store-nope", Ecto.UUID.generate(), embedding, %{},
                 repo: repo,
                 strict_collections: true
               )

      assert repo.get_by(Collection, name: "strict-store-nope") == nil
    end
  end

  describe "search/3 with a pre-resolved collection id" do
    test "the :collection_id opt pins the query instead of re-resolving the name" do
      repo = Arcana.TestRepo
      embedding = List.duplicate(0.5, 384)

      {:ok, collection} = Collection.get_or_create("pinned-coll", repo)
      {:ok, other} = Collection.get_or_create("pinned-other", repo)

      for {coll, text} <- [{collection, "pinned chunk"}, {other, "foreign chunk"}] do
        {:ok, doc} =
          %Document{}
          |> Document.changeset(%{content: "x", status: :completed, collection_id: coll.id})
          |> repo.insert()

        %Chunk{}
        |> Chunk.changeset(%{text: text, embedding: embedding, document_id: doc.id})
        |> repo.insert!()
      end

      # The name doesn't resolve, but the id filter must still apply: the
      # equally-similar chunk in the other collection must be excluded
      # (without the pin this query would widen and return both).
      results =
        Pgvector.search("renamed-since-validation", embedding,
          repo: repo,
          collection_id: collection.id
        )

      assert [%{metadata: %{text: "pinned chunk"}}] = results
    end

    test "under strict mode a direct backend call with an unknown name matches nothing" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("strict-direct", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{content: "x", status: :completed, collection_id: collection.id})
        |> repo.insert()

      %Chunk{}
      |> Chunk.changeset(%{
        text: "in collection",
        embedding: List.duplicate(0.5, 384),
        document_id: doc.id
      })
      |> repo.insert!()

      # Non-strict keeps the historical fail-open (global) behavior
      refute Pgvector.search("strict-nope", List.duplicate(0.5, 384), repo: repo) == []

      # Strict fails closed instead of widening to a global search
      assert Pgvector.search("strict-nope", List.duplicate(0.5, 384),
               repo: repo,
               strict_collections: true
             ) == []

      assert Pgvector.search_text("strict-nope", "collection",
               repo: repo,
               strict_collections: true
             ) == []

      assert Pgvector.search_hybrid("strict-nope", List.duplicate(0.5, 384), "collection",
               repo: repo,
               strict_collections: true
             ) == []
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

    test "with strict_collections, an unknown collection blocks the delete" do
      repo = Arcana.TestRepo

      {:ok, collection} = Collection.get_or_create("strict-delete-test", repo)

      {:ok, doc} =
        %Document{}
        |> Document.changeset(%{
          content: "test",
          status: :completed,
          collection_id: collection.id
        })
        |> repo.insert()

      {:ok, chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "kept",
          embedding: List.duplicate(0.5, 384),
          document_id: doc.id
        })
        |> repo.insert()

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Pgvector.delete("strict-nope", chunk.id, repo: repo, strict_collections: true)

      assert repo.get(Chunk, chunk.id)
    end
  end

  describe "clear/2" do
    test "with strict_collections, an unknown collection is an error instead of a no-op" do
      repo = Arcana.TestRepo

      assert :ok = Pgvector.clear("strict-nope", repo: repo)

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Pgvector.clear("strict-nope", repo: repo, strict_collections: true)
    end

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
          repo: repo,
          limit: 10
        )

      assert length(results) == 2

      # Results should have combined scores
      first = hd(results)
      assert first.score > 0
      assert first.metadata[:vector_score] > 0
      assert first.metadata[:keyword_score] >= 0
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
          repo: repo,
          vector_weight: 0.9,
          keyword_weight: 0.1
        )

      fulltext_heavy =
        Pgvector.search_hybrid(
          "weight-test",
          embedding,
          "test",
          repo: repo,
          vector_weight: 0.1,
          keyword_weight: 0.9
        )

      assert length(semantic_heavy) == 1
      assert length(fulltext_heavy) == 1

      # Scores should differ based on weights
      # (both will return same chunk but with different combined scores)
      semantic_result = hd(semantic_heavy)
      fulltext_result = hd(fulltext_heavy)

      # Both should have the individual scores
      assert semantic_result.metadata[:vector_score] > 0
      assert fulltext_result.metadata[:vector_score] > 0
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

      # Genuinely low-scoring on both halves. The previous version used
      # normalize([0.1] ++ zeros) as the "low-similarity" embedding, which
      # normalizes to the same unit vector as the query - so the vector score was
      # 1.0, and the blend only stayed under the threshold because a real keyword
      # match was being zeroed by the min == max branch this fix removed.
      embedding = normalize([1.0, 1.0] ++ List.duplicate(0.0, 382))
      query = normalize([1.0] ++ List.duplicate(0.0, 383))

      {:ok, _chunk} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: "nothing in common",
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
          repo: repo,
          threshold: 0.9
        )

      # Combined score unlikely to exceed 0.9 threshold
      assert results == []

      # With low threshold, should return results
      results_low =
        Pgvector.search_hybrid(
          "threshold-hybrid-test",
          query,
          "unrelated",
          repo: repo,
          threshold: 0.0
        )

      assert length(results_low) == 1
    end
  end

  # Helper to normalize a vector to unit length
  defp normalize_uuid(<<_::128>> = uuid), do: Ecto.UUID.load!(uuid)
  defp normalize_uuid(uuid), do: uuid

  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, fn x, sum -> sum + x * x end))

    if magnitude > 0 do
      Enum.map(vector, &(&1 / magnitude))
    else
      vector
    end
  end
end
