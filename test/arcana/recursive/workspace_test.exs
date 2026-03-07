defmodule Arcana.Recursive.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Arcana.Recursive.Workspace

  @single_doc "Line one\nLine two\nLine three\nLine four\nLine five"

  @multi_docs [
    %{
      name: "report.txt",
      text: "Revenue grew 15% in Q3.\nCosts remained stable.\nProfit margins improved."
    },
    %{
      name: "analysis.md",
      text: "The market showed strong growth.\nCompetitors struggled with supply chain issues."
    }
  ]

  describe "from_content/1 with a single string" do
    test "creates workspace with one document" do
      ws = Workspace.from_content(@single_doc)

      assert map_size(ws.documents) == 1
      assert ws.documents["doc_1"].text == @single_doc
      assert ws.documents["doc_1"].name == "doc_1"
      assert ws.documents["doc_1"].line_count == 5
    end
  end

  describe "from_content/1 with a list of documents" do
    test "creates workspace with named documents" do
      ws = Workspace.from_content(@multi_docs)

      assert map_size(ws.documents) == 2

      assert ws.documents["report.txt"].text ==
               "Revenue grew 15% in Q3.\nCosts remained stable.\nProfit margins improved."

      assert ws.documents["report.txt"].line_count == 3
      assert ws.documents["analysis.md"].line_count == 2
    end
  end

  describe "grep/2" do
    test "finds matches with line numbers and context" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, matches} = Workspace.grep(ws, "grew")

      assert length(matches) == 1
      [match] = matches
      assert match.document == "report.txt"
      assert match.line_number == 1
      assert match.line =~ "Revenue grew 15%"
    end

    test "finds matches across multiple documents" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, matches} = Workspace.grep(ws, "growth|grew")

      assert length(matches) == 2
      docs = Enum.map(matches, & &1.document) |> Enum.sort()
      assert docs == ["analysis.md", "report.txt"]
    end

    test "returns empty list for no matches" do
      ws = Workspace.from_content(@single_doc)
      {:ok, matches} = Workspace.grep(ws, "nonexistent")

      assert matches == []
    end

    test "handles invalid regex gracefully" do
      ws = Workspace.from_content(@single_doc)
      {:error, _reason} = Workspace.grep(ws, "[invalid")
    end

    test "is case insensitive by default" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, matches} = Workspace.grep(ws, "revenue")

      assert length(matches) == 1
    end
  end

  describe "read_section/3" do
    test "reads a range of lines from a document" do
      ws = Workspace.from_content(@single_doc)
      {:ok, text} = Workspace.read_section(ws, "doc_1", {2, 4})

      assert text == "Line two\nLine three\nLine four"
    end

    test "reads from a named document" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, text} = Workspace.read_section(ws, "report.txt", {1, 2})

      assert text == "Revenue grew 15% in Q3.\nCosts remained stable."
    end

    test "clamps to document bounds" do
      ws = Workspace.from_content(@single_doc)
      {:ok, text} = Workspace.read_section(ws, "doc_1", {3, 100})

      assert text == "Line three\nLine four\nLine five"
    end

    test "returns error for unknown document" do
      ws = Workspace.from_content(@single_doc)
      {:error, :not_found} = Workspace.read_section(ws, "nonexistent", {1, 5})
    end

    test "reads entire document when no range given" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, text} = Workspace.read_section(ws, "report.txt", :all)

      assert text == "Revenue grew 15% in Q3.\nCosts remained stable.\nProfit margins improved."
    end
  end

  describe "overview/1" do
    test "shows document names and line counts" do
      ws = Workspace.from_content(@multi_docs)
      overview = Workspace.overview(ws)

      assert overview =~ "report.txt"
      assert overview =~ "analysis.md"
      assert overview =~ "3 lines"
      assert overview =~ "2 lines"
    end

    test "shows empty state" do
      ws = %Workspace{}
      overview = Workspace.overview(ws)

      assert overview =~ "empty"
    end

    test "grep does not mutate workspace overview" do
      ws = Workspace.from_content(@multi_docs)
      {:ok, _matches} = Workspace.grep(ws, "grew")
      overview = Workspace.overview(ws)

      # Workspace is immutable — grep results tracked in session, not here
      assert overview =~ "report.txt"
      refute overview =~ "grew"
    end
  end

  describe "subset/2" do
    test "creates workspace with only specified documents" do
      ws = Workspace.from_content(@multi_docs)
      sub = Workspace.subset(ws, ["report.txt"])

      assert map_size(sub.documents) == 1
      assert Map.has_key?(sub.documents, "report.txt")
      refute Map.has_key?(sub.documents, "analysis.md")
    end
  end

  describe "document_count/1 and total_lines/1" do
    test "returns correct counts" do
      ws = Workspace.from_content(@multi_docs)

      assert Workspace.document_count(ws) == 2
      assert Workspace.total_lines(ws) == 5
    end
  end

  describe "total_bytes/1" do
    test "returns total size of all documents" do
      ws = Workspace.from_content(@multi_docs)
      bytes = Workspace.total_bytes(ws)

      assert bytes > 0
      expected = byte_size(Enum.map_join(@multi_docs, & &1.text))
      assert bytes == expected
    end
  end
end
