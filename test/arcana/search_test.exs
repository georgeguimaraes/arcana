defmodule Arcana.SearchTest do
  use Arcana.DataCase, async: true

  describe "search/2" do
    setup do
      # Ingest some documents for searching
      {:ok, doc1} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
      {:ok, doc2} = Arcana.ingest("Python is great for machine learning.", repo: Repo)
      {:ok, doc3} = Arcana.ingest("The weather today is sunny and warm.", repo: Repo)

      %{doc1: doc1, doc2: doc2, doc3: doc3}
    end

    test "finds relevant chunks", %{doc1: doc1} do
      {:ok, results} = Arcana.search("functional programming", repo: Repo)

      refute Enum.empty?(results)
      # First result should be from the Elixir document
      first = hd(results)
      assert first.document_id == doc1.id
      assert first.score > 0
    end

    test "respects limit option" do
      {:ok, results} = Arcana.search("programming", repo: Repo, limit: 2)

      assert length(results) <= 2
    end

    test "filters by source_id" do
      {:ok, _scoped_doc} =
        Arcana.ingest("Ruby programming language", repo: Repo, source_id: "scope-a")

      {:ok, results} = Arcana.search("programming", repo: Repo, source_id: "scope-a")

      refute Enum.empty?(results)

      assert Enum.all?(results, fn r ->
               doc = Repo.get!(Arcana.Document, r.document_id)
               doc.source_id == "scope-a"
             end)
    end

    test "fulltext mode finds exact keyword matches" do
      # Search for exact word "Elixir" - fulltext should find it
      {:ok, results} = Arcana.search("Elixir", repo: Repo, mode: :fulltext)

      refute Enum.empty?(results)
      # Verify the result contains the exact word
      assert String.contains?(hd(results).text, "Elixir")
    end

    test "fulltext mode uses ts_rank scoring" do
      # Fulltext should return results with rank-based scoring
      {:ok, results} =
        Arcana.search("functional programming language", repo: Repo, mode: :fulltext)

      refute Enum.empty?(results)
      # ts_rank scores are typically small positive numbers
      first = hd(results)
      assert first.score > 0
      assert first.score < 1.0
    end

    test "hybrid mode combines vector and fulltext with RRF" do
      {:ok, results} = Arcana.search("Elixir functional", repo: Repo, mode: :hybrid)

      refute Enum.empty?(results)
      # RRF scores are in range 0-1
      first = hd(results)
      assert first.score > 0
      assert first.score <= 1.0
    end

    test "hybrid mode returns individual semantic and fulltext scores" do
      {:ok, results} = Arcana.search("Elixir functional", repo: Repo, mode: :hybrid)

      refute Enum.empty?(results)
      first = hd(results)

      # Single-query hybrid should include both score breakdowns
      assert Map.has_key?(first, :semantic_score)
      assert Map.has_key?(first, :fulltext_score)
      assert is_number(first.semantic_score)
      assert is_number(first.fulltext_score)
    end

    test "hybrid mode respects semantic_weight and fulltext_weight options" do
      # Test with heavily weighted semantic
      {:ok, semantic_heavy} =
        Arcana.search("Elixir",
          repo: Repo,
          mode: :hybrid,
          semantic_weight: 0.9,
          fulltext_weight: 0.1
        )

      # Test with heavily weighted fulltext
      {:ok, fulltext_heavy} =
        Arcana.search("Elixir",
          repo: Repo,
          mode: :hybrid,
          semantic_weight: 0.1,
          fulltext_weight: 0.9
        )

      refute Enum.empty?(semantic_heavy)
      refute Enum.empty?(fulltext_heavy)
    end

    test "raises error for invalid mode" do
      assert_raise ArgumentError, ~r/invalid search mode/, fn ->
        Arcana.search("test", repo: Repo, mode: :invalid_mode)
      end
    end

    test "filters by single collection" do
      # Collection is auto-created on ingest
      {:ok, _doc} =
        Arcana.ingest("Ruby is a dynamic programming language",
          repo: Repo,
          collection: "search-coll"
        )

      {:ok, results} = Arcana.search("programming", repo: Repo, collection: "search-coll")

      refute Enum.empty?(results)
      assert Enum.all?(results, fn r -> String.contains?(r.text, "Ruby") end)
    end

    test "filters by multiple collections using :collections option" do
      # Collections are auto-created on ingest
      {:ok, _doc1} =
        Arcana.ingest("Go is a statically typed language",
          repo: Repo,
          collection: "search-coll-a"
        )

      {:ok, _doc2} =
        Arcana.ingest("Rust is a systems programming language",
          repo: Repo,
          collection: "search-coll-b"
        )

      {:ok, _doc3} =
        Arcana.ingest("JavaScript is a web language", repo: Repo, collection: "search-coll-c")

      # Search only in collections a and b
      {:ok, results} =
        Arcana.search("language", repo: Repo, collections: ["search-coll-a", "search-coll-b"])

      refute Enum.empty?(results)
      texts = Enum.map(results, & &1.text)

      # Should find Go and Rust but not JavaScript
      assert Enum.any?(texts, &String.contains?(&1, "Go"))
      assert Enum.any?(texts, &String.contains?(&1, "Rust"))
      refute Enum.any?(texts, &String.contains?(&1, "JavaScript"))
    end
  end

  describe "rewrite_query/2" do
    test "rewrites query using provided function" do
      rewriter = fn query ->
        {:ok, "expanded: #{query} programming language"}
      end

      {:ok, rewritten} = Arcana.rewrite_query("Elixir", rewriter: rewriter)

      assert rewritten == "expanded: Elixir programming language"
    end

    test "returns error when no rewriter configured" do
      assert {:error, :no_rewriter_configured} = Arcana.rewrite_query("test")
    end

    test "passes through rewriter errors" do
      rewriter = fn _query ->
        {:error, :llm_unavailable}
      end

      assert {:error, :llm_unavailable} = Arcana.rewrite_query("test", rewriter: rewriter)
    end
  end

  describe "search/2 with rewriter" do
    setup do
      {:ok, doc} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
      {:ok, weather_doc} = Arcana.ingest("The weather today is sunny and warm.", repo: Repo)
      %{doc: doc, weather_doc: weather_doc}
    end

    test "applies rewriter before searching", %{doc: doc} do
      test_pid = self()

      # Rewriter expands query and reports what it received
      rewriter = fn query ->
        send(test_pid, {:rewriter_called, query})
        {:ok, "functional programming language"}
      end

      {:ok, results} = Arcana.search("xyz123", repo: Repo, rewriter: rewriter)

      # Verify rewriter was called with original query
      assert_receive {:rewriter_called, "xyz123"}
      # Verify search used rewritten query to find functional programming doc
      refute Enum.empty?(results)
      assert hd(results).document_id == doc.id
    end

    test "uses original query when rewriter returns error" do
      rewriter = fn _query ->
        {:error, :failed}
      end

      # Should fall back to original query, still find results
      {:ok, results} = Arcana.search("Elixir", repo: Repo, rewriter: rewriter)

      refute Enum.empty?(results)
    end
  end
end
