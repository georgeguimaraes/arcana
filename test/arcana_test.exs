defmodule ArcanaTest do
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

    test "fulltext mode finds exact keyword matches" do
      # Search for exact word "Elixir" - fulltext should find it
      results = Arcana.search("Elixir", repo: Repo, mode: :fulltext)

      refute Enum.empty?(results)
      # Verify the result contains the exact word
      assert String.contains?(hd(results).text, "Elixir")
    end

    test "fulltext mode uses ts_rank scoring" do
      # Fulltext should return results with rank-based scoring
      results = Arcana.search("functional programming language", repo: Repo, mode: :fulltext)

      refute Enum.empty?(results)
      # ts_rank scores are typically small positive numbers
      first = hd(results)
      assert first.score > 0
      assert first.score < 1.0
    end

    test "hybrid mode combines vector and fulltext with RRF" do
      results = Arcana.search("Elixir functional", repo: Repo, mode: :hybrid)

      refute Enum.empty?(results)
      # RRF scores are in range 0-1
      first = hd(results)
      assert first.score > 0
      assert first.score <= 1.0
    end

    test "hybrid mode returns individual semantic and fulltext scores" do
      results = Arcana.search("Elixir functional", repo: Repo, mode: :hybrid)

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
      semantic_heavy =
        Arcana.search("Elixir",
          repo: Repo,
          mode: :hybrid,
          semantic_weight: 0.9,
          fulltext_weight: 0.1
        )

      # Test with heavily weighted fulltext
      fulltext_heavy =
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

      results = Arcana.search("programming", repo: Repo, collection: "search-coll")

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
      results =
        Arcana.search("language", repo: Repo, collections: ["search-coll-a", "search-coll-b"])

      refute Enum.empty?(results)
      texts = Enum.map(results, & &1.text)

      # Should find Go and Rust but not JavaScript
      assert Enum.any?(texts, &String.contains?(&1, "Go"))
      assert Enum.any?(texts, &String.contains?(&1, "Rust"))
      refute Enum.any?(texts, &String.contains?(&1, "JavaScript"))
    end
  end

  describe "ask/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest(
          "The capital of France is Paris. Paris is known for the Eiffel Tower.",
          repo: Repo
        )

      :ok
    end

    test "works with any type implementing Arcana.LLM protocol" do
      # Anonymous function implements the protocol via Function
      llm = fn prompt, context ->
        {:ok, "Answer to: #{prompt} with #{length(context)} chunks"}
      end

      {:ok, answer, _results} = Arcana.ask("What is the capital?", repo: Repo, llm: llm)

      assert answer =~ "What is the capital?"
      assert answer =~ "chunks"
    end

    test "accepts model string via protocol (requires req_llm)" do
      # Verify that a model string is accepted (protocol is implemented for BitString)
      # We can't actually call the API, but we can verify the protocol implementation exists
      model = "openai:gpt-4o-mini"

      # This should not raise - the protocol implementation exists
      assert Arcana.LLM.impl_for(model) != nil
    end

    test "returns answer using retrieved context" do
      # Use a test LLM that echoes the context
      test_llm = fn prompt, _context ->
        {:ok, "Answer based on: #{prompt}"}
      end

      {:ok, answer, _results} =
        Arcana.ask("What is the capital of France?",
          repo: Repo,
          llm: test_llm
        )

      assert answer =~ "capital of France"
    end

    test "passes retrieved chunks as context to LLM" do
      # Track what context was passed to the LLM
      test_pid = self()

      test_llm = fn prompt, context ->
        send(test_pid, {:llm_called, prompt, context})
        {:ok, "Test answer"}
      end

      {:ok, _answer, _results} =
        Arcana.ask("Tell me about Paris",
          repo: Repo,
          llm: test_llm
        )

      assert_receive {:llm_called, prompt, context}
      assert prompt =~ "Paris"
      assert is_list(context)
      assert not Enum.empty?(context)
      # Context should contain the ingested document chunks
      assert Enum.any?(context, fn chunk -> chunk.text =~ "Paris" end)
    end

    test "returns error when no LLM configured" do
      assert {:error, :no_llm_configured} = Arcana.ask("test", repo: Repo)
    end

    test "respects search options like limit and threshold" do
      test_pid = self()

      test_llm = fn _prompt, context ->
        send(test_pid, {:context_size, length(context)})
        {:ok, "Answer"}
      end

      {:ok, _, _} =
        Arcana.ask("Paris",
          repo: Repo,
          llm: test_llm,
          limit: 1
        )

      assert_receive {:context_size, 1}
    end

    test "accepts custom prompt function" do
      test_pid = self()

      # LLM that captures the system prompt it receives
      test_llm = fn prompt, context, opts ->
        send(test_pid, {:llm_called, prompt, context, opts})
        {:ok, "Answer"}
      end

      custom_prompt = fn question, context ->
        "CUSTOM SYSTEM: Answer '#{question}' using #{length(context)} sources"
      end

      {:ok, _, _} =
        Arcana.ask("What is Paris?",
          repo: Repo,
          llm: test_llm,
          prompt: custom_prompt
        )

      assert_receive {:llm_called, _prompt, _context, opts}
      assert opts[:system_prompt] =~ "CUSTOM SYSTEM"
      assert opts[:system_prompt] =~ "What is Paris?"
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

      results = Arcana.search("xyz123", repo: Repo, rewriter: rewriter)

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
      results = Arcana.search("Elixir", repo: Repo, rewriter: rewriter)

      refute Enum.empty?(results)
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
