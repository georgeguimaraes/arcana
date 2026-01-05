defmodule Arcana.ParserTest do
  use ExUnit.Case, async: true

  alias Arcana.Parser

  describe "parse/2 with text files" do
    test "extracts text from .txt files" do
      path = create_temp_file("hello world", ".txt")

      assert {:ok, "hello world"} = Parser.parse(path)
    end

    test "preserves newlines in text files" do
      content = "line one\nline two\nline three"
      path = create_temp_file(content, ".txt")

      assert {:ok, ^content} = Parser.parse(path)
    end
  end

  describe "parse/2 with markdown files" do
    test "extracts text from .md files" do
      content = "# Header\n\nSome **bold** text"
      path = create_temp_file(content, ".md")

      assert {:ok, ^content} = Parser.parse(path)
    end
  end

  describe "pdf_support_available?/0" do
    test "returns boolean indicating pdftotext availability" do
      result = Parser.pdf_support_available?()
      assert is_boolean(result)
    end
  end

  describe "parse/2 with PDF files" do
    @tag :pdf_support
    test "extracts text from PDF files" do
      if Parser.pdf_support_available?() do
        path = fixture_path("sample.pdf")

        assert {:ok, text} = Parser.parse(path)
        assert String.contains?(text, "Hello PDF")
      else
        # Skip if pdftotext not installed
        :ok
      end
    end

    test "returns error for corrupted PDF" do
      path = create_temp_file("not a real pdf", ".pdf")

      assert {:error, reason} = Parser.parse(path)
      # :invalid_pdf when file doesn't start with %PDF magic bytes
      assert reason == :invalid_pdf
    end

    test "returns error when PDF parser not available" do
      # This tests the error path - we can't easily test without pdftotext
      # but we verify the function exists and returns expected types
      path = fixture_path("sample.pdf")

      case Parser.parse(path) do
        {:ok, _text} -> assert Parser.pdf_support_available?()
        {:error, :poppler_not_available} -> refute Parser.pdf_support_available?()
        {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
      end
    end
  end

  describe "parse/2 with unsupported formats" do
    test "returns error for unsupported file types" do
      path = create_temp_file("data", ".xyz")

      assert {:error, :unsupported_format} = Parser.parse(path)
    end
  end

  describe "parse/2 with missing files" do
    test "returns error for non-existent files" do
      assert {:error, :file_not_found} = Parser.parse("/nonexistent/file.txt")
    end
  end

  describe "supported_formats/0" do
    test "returns list of supported extensions" do
      formats = Parser.supported_formats()

      assert ".txt" in formats
      assert ".md" in formats
      assert ".pdf" in formats
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
