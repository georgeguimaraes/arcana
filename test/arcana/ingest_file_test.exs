defmodule Arcana.IngestFileTest do
  use Arcana.DataCase, async: true

  alias Arcana.Parser

  describe "ingest_file/2" do
    test "ingests a text file and creates document with chunks" do
      path = create_temp_file("This is test content for ingestion.", ".txt")

      assert {:ok, document} = Arcana.ingest_file(path, repo: Arcana.TestRepo)

      assert document.content == "This is test content for ingestion."
      assert document.status == :completed
      assert document.file_path == path
      assert document.content_type == "text/plain"
    end

    test "ingests a markdown file" do
      content = "# Title\n\nSome paragraph with **bold** text."
      path = create_temp_file(content, ".md")

      assert {:ok, document} = Arcana.ingest_file(path, repo: Arcana.TestRepo)

      assert document.content == content
      assert document.content_type == "text/markdown"
    end

    @tag :pdf_support
    test "ingests a PDF file" do
      if Parser.pdf_support_available?() do
        path = fixture_path("sample.pdf")

        assert {:ok, document} = Arcana.ingest_file(path, repo: Arcana.TestRepo)

        assert String.contains?(document.content, "Hello PDF")
        assert document.content_type == "application/pdf"
        assert document.file_path == path
      else
        # Skip if pdftotext not installed
        :ok
      end
    end

    test "returns error when PDF support not available" do
      path = fixture_path("sample.pdf")

      case Arcana.ingest_file(path, repo: Arcana.TestRepo) do
        {:ok, _document} ->
          assert Parser.pdf_support_available?()

        {:error, :pdf_support_not_available} ->
          refute Parser.pdf_support_available?()

        # Poppler returns :poppler_not_available when pdftotext is not installed
        {:error, :poppler_not_available} ->
          refute Parser.pdf_support_available?()

        {:error, other} ->
          flunk("Unexpected error: #{inspect(other)}")
      end
    end

    test "stores file_path in document metadata" do
      path = create_temp_file("content", ".txt")

      assert {:ok, document} = Arcana.ingest_file(path, repo: Arcana.TestRepo)

      assert document.file_path == path
    end

    test "accepts source_id option" do
      path = create_temp_file("content", ".txt")

      assert {:ok, document} =
               Arcana.ingest_file(path, repo: Arcana.TestRepo, source_id: "my-source")

      assert document.source_id == "my-source"
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} =
               Arcana.ingest_file("/nonexistent/file.txt", repo: Arcana.TestRepo)
    end

    test "returns error for unsupported format" do
      path = create_temp_file("data", ".xyz")

      assert {:error, :unsupported_format} =
               Arcana.ingest_file(path, repo: Arcana.TestRepo)
    end
  end

  # Helper functions

  defp create_temp_file(content, extension) do
    dir = System.tmp_dir!()
    filename = "arcana_test_#{:rand.uniform(100_000)}#{extension}"
    path = Path.join(dir, filename)
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp fixture_path(filename) do
    Path.join([__DIR__, "..", "fixtures", filename])
  end
end
