defmodule Arcana.Agent.SearchTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

  describe "search/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language.",
          repo: Arcana.TestRepo
        )

      :ok
    end

    test "searches and populates results" do
      ctx =
        Agent.new("functional programming", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search()

      assert is_list(ctx.results)
      refute Enum.empty?(ctx.results)

      [first | _] = ctx.results
      assert first.question == "functional programming"
      assert first.collection == "default"
      assert is_list(first.chunks)
    end

    test "respects limit option" do
      ctx =
        Agent.new("programming", repo: Arcana.TestRepo, llm: &mock_llm/1, limit: 1)
        |> Agent.search()

      [result | _] = ctx.results
      assert length(result.chunks) <= 1
    end

    test "uses sub_questions if present" do
      ctx =
        %Context{
          question: "original",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          sub_questions: ["Elixir", "functional"]
        }
        |> Agent.search()

      assert length(ctx.results) == 2
      questions = Enum.map(ctx.results, & &1.question)
      assert "Elixir" in questions
      assert "functional" in questions
    end

    test "uses collections if present" do
      # Create a document in a specific collection
      {:ok, _} =
        Arcana.ingest("Python is also great.",
          repo: Arcana.TestRepo,
          collection: "other-langs"
        )

      ctx =
        %Context{
          question: "programming",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          collections: ["default", "other-langs"]
        }
        |> Agent.search()

      # Should have results for each collection
      collections = Enum.map(ctx.results, & &1.collection)
      assert "default" in collections
      assert "other-langs" in collections
    end

    test "uses :collection option to search specific collection" do
      {:ok, _} =
        Arcana.ingest("Ruby is a programming language.",
          repo: Arcana.TestRepo,
          collection: "ruby-docs"
        )

      ctx =
        Agent.new("programming", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(collection: "ruby-docs")

      # Should only search the specified collection
      assert length(ctx.results) == 1
      [result] = ctx.results
      assert result.collection == "ruby-docs"
    end

    test "uses :collections option to search multiple collections" do
      {:ok, _} =
        Arcana.ingest("Go is a systems language.",
          repo: Arcana.TestRepo,
          collection: "go-docs"
        )

      {:ok, _} =
        Arcana.ingest("Rust is memory safe.",
          repo: Arcana.TestRepo,
          collection: "rust-docs"
        )

      ctx =
        Agent.new("language", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(collections: ["go-docs", "rust-docs"])

      # Should search both collections
      collections = Enum.map(ctx.results, & &1.collection)
      assert "go-docs" in collections
      assert "rust-docs" in collections
    end

    test "option takes priority over ctx.collections" do
      {:ok, _} =
        Arcana.ingest("Haskell is purely functional.",
          repo: Arcana.TestRepo,
          collection: "haskell-docs"
        )

      ctx =
        %Context{
          question: "functional",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          collections: ["default"]
        }
        |> Agent.search(collection: "haskell-docs")

      # Option should override ctx.collections
      assert length(ctx.results) == 1
      [result] = ctx.results
      assert result.collection == "haskell-docs"
    end

    test "skips search when skip_retrieval is true" do
      ctx =
        %Context{
          question: "What is 2 + 2?",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          skip_retrieval: true
        }
        |> Agent.search()

      # Should not have searched - results should be empty
      assert ctx.results == []
    end

    test "performs search when skip_retrieval is false" do
      ctx =
        %Context{
          question: "functional programming",
          repo: Arcana.TestRepo,
          llm: &mock_llm/1,
          limit: 5,
          threshold: 0.5,
          skip_retrieval: false
        }
        |> Agent.search()

      # Should have searched
      refute Enum.empty?(ctx.results)
    end

    test "performs search when skip_retrieval is nil (default)" do
      ctx =
        Agent.new("functional programming", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search()

      # Default behavior - should search
      refute Enum.empty?(ctx.results)
    end
  end

  describe "custom searcher" do
    test "accepts custom searcher module" do
      defmodule TestSearcher do
        @behaviour Arcana.Agent.Searcher

        @impl true
        def search(_question, _collection, _opts) do
          chunks = [
            %{id: "custom-1", text: "Custom search result", metadata: %{}, similarity: 0.9}
          ]

          {:ok, chunks}
        end
      end

      ctx =
        Agent.new("anything", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: TestSearcher)

      [result | _] = ctx.results
      [chunk | _] = result.chunks
      assert chunk.id == "custom-1"
      assert chunk.text == "Custom search result"
    end

    test "accepts custom searcher function" do
      custom_searcher = fn question, _collection, _opts ->
        {:ok,
         [%{id: "fn-1", text: "Function search: #{question}", metadata: %{}, similarity: 1.0}]}
      end

      ctx =
        Agent.new("test query", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: custom_searcher)

      [result | _] = ctx.results
      [chunk | _] = result.chunks
      assert chunk.id == "fn-1"
      assert chunk.text =~ "test query"
    end

    test "returns empty results on searcher error" do
      custom_searcher = fn _question, _collection, _opts ->
        {:error, :search_failed}
      end

      ctx =
        Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)
        |> Agent.search(searcher: custom_searcher)

      [result | _] = ctx.results
      assert result.chunks == []
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
