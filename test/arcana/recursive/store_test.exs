defmodule Arcana.Recursive.StoreTest do
  use Arcana.DataCase, async: true

  alias Arcana.Recursive

  defp mock_tool_call_response(tool_name, args) do
    tool_call = ReqLLM.ToolCall.new(Uniq.UUID.uuid7(), tool_name, JSON.encode!(args))

    %ReqLLM.Response{
      id: Uniq.UUID.uuid7(),
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant("", tool_calls: [tool_call]),
      finish_reason: :tool_calls,
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  defp mock_text_response(text) do
    %ReqLLM.Response{
      id: Uniq.UUID.uuid7(),
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 20}
    }
  end

  describe "store/2" do
    test "stores a document with full text" do
      {:ok, doc} =
        Recursive.store("The 2008 financial crisis began with subprime mortgages.",
          repo: Repo,
          collection: "research",
          name: "crisis-report.pdf"
        )

      assert doc.content == "The 2008 financial crisis began with subprime mortgages."
      assert doc.file_path == "crisis-report.pdf"
      assert doc.status == :completed

      # Verify it's in the DB
      reloaded = Repo.get!(Arcana.Document, doc.id)
      assert reloaded.content == doc.content
    end

    test "creates collection if it doesn't exist" do
      {:ok, _doc} =
        Recursive.store("Some content",
          repo: Repo,
          collection: "new-collection",
          name: "doc.txt"
        )

      collection = Repo.get_by!(Arcana.Collection, name: "new-collection")
      assert collection.name == "new-collection"
    end

    test "reuses existing collection" do
      {:ok, _} = Arcana.Collection.get_or_create("existing", Repo)

      {:ok, doc1} =
        Recursive.store("First doc", repo: Repo, collection: "existing", name: "doc1.txt")

      {:ok, doc2} =
        Recursive.store("Second doc", repo: Repo, collection: "existing", name: "doc2.txt")

      assert doc1.collection_id == doc2.collection_id
    end

    test "defaults to 'default' collection" do
      {:ok, doc} = Recursive.store("Content", repo: Repo, name: "test.txt")

      collection = Repo.get_by!(Arcana.Collection, name: "default")
      assert doc.collection_id == collection.id
    end

    test "stores metadata" do
      {:ok, doc} =
        Recursive.store("Content",
          repo: Repo,
          name: "doc.txt",
          metadata: %{"source" => "upload", "author" => "George"}
        )

      assert doc.metadata == %{"source" => "upload", "author" => "George"}
    end

    test "raises without repo" do
      assert_raise ArgumentError, ~r/:repo is required/, fn ->
        Recursive.store("Content", name: "doc.txt")
      end
    end
  end

  describe "explore/2 with collection-backed mode" do
    test "loads documents from collection" do
      {:ok, _} =
        Recursive.store("Revenue grew 15% in Q3.\nCosts remained stable.",
          repo: Repo,
          collection: "quarterly",
          name: "q3-report.txt"
        )

      {:ok, _} =
        Recursive.store("Market share increased to 23%.\nCompetitors struggled.",
          repo: Repo,
          collection: "quarterly",
          name: "market-analysis.txt"
        )

      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "revenue|market"})}
        else
          {:ok, mock_text_response("Revenue grew and market share increased.")}
        end
      end

      {:ok, result} =
        Recursive.explore("What happened?",
          model: mock_model,
          repo: Repo,
          collection: "quarterly"
        )

      assert result.answer == "Revenue grew and market share increased."
      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 2
      assert Map.has_key?(result.workspace.documents, "q3-report.txt")
      assert Map.has_key?(result.workspace.documents, "market-analysis.txt")
    end

    test "only loads completed documents" do
      {:ok, _doc} =
        Recursive.store("Good content",
          repo: Repo,
          collection: "status-test",
          name: "good.txt"
        )

      # Insert a processing document directly
      {:ok, collection} = Arcana.Collection.get_or_create("status-test", Repo)

      {:ok, _} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Still processing",
          file_path: "pending.txt",
          status: :processing,
          collection_id: collection.id
        })
        |> Repo.insert()

      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("done")}
      end

      {:ok, result} =
        Recursive.explore("Check status",
          model: mock_model,
          repo: Repo,
          collection: "status-test"
        )

      # Should only have the completed document
      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 1
      assert Map.has_key?(result.workspace.documents, "good.txt")
      refute Map.has_key?(result.workspace.documents, "pending.txt")
    end

    test "uses document ID as name when file_path is nil" do
      {:ok, collection} = Arcana.Collection.get_or_create("no-name-test", Repo)

      {:ok, doc} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Anonymous content",
          status: :completed,
          collection_id: collection.id
        })
        |> Repo.insert()

      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("done")}
      end

      {:ok, result} =
        Recursive.explore("Check",
          model: mock_model,
          repo: Repo,
          collection: "no-name-test"
        )

      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 1
      assert Map.has_key?(result.workspace.documents, doc.id)
    end

    test "multiple collections" do
      {:ok, _} =
        Recursive.store("Report A content", repo: Repo, collection: "reports", name: "a.txt")

      {:ok, _} =
        Recursive.store("Analysis B content", repo: Repo, collection: "analyses", name: "b.txt")

      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("done")}
      end

      {:ok, result} =
        Recursive.explore("Cross-collection",
          model: mock_model,
          repo: Repo,
          collections: ["reports", "analyses"]
        )

      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 2
      assert Map.has_key?(result.workspace.documents, "a.txt")
      assert Map.has_key?(result.workspace.documents, "b.txt")
    end

    test "empty collection returns empty workspace" do
      {:ok, _} = Arcana.Collection.get_or_create("empty", Repo)

      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("nothing to explore")}
      end

      {:ok, result} =
        Recursive.explore("Explore nothing",
          model: mock_model,
          repo: Repo,
          collection: "empty"
        )

      assert result.answer == "nothing to explore"
      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 0
    end
  end
end
