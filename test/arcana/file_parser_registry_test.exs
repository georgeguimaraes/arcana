defmodule FakeDocxParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(input, opts) do
    label = Keyword.get(opts, :label, "docx")

    if String.starts_with?(input, "/") do
      {:ok, "#{label} from path"}
    else
      {:ok, "#{label} from binary"}
    end
  end

  @impl true
  def supports_binary?, do: true
end

defmodule PathOnlyParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: {:ok, "path only"}
end

defmodule PagedParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts) do
    {:ok, "page one\npage two", %{pages: [%{number: 1, start: 0, end: 8}]}}
  end

  @impl true
  def supports_binary?, do: true
end

defmodule UnavailableParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: {:ok, ""}

  @impl true
  def available?, do: false
end

defmodule Arcana.FileParserRegistryTest do
  use Arcana.DataCase, async: true

  alias Arcana.Parser

  defp temp_file(content, extension) do
    path =
      Path.join(System.tmp_dir!(), "arcana_reg_#{System.unique_integer([:positive])}#{extension}")

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "registered parsers" do
    test "an extension registered in :file_parsers is routed to its parser" do
      put_arcana_env(:file_parsers, %{".docx" => {FakeDocxParser, label: "custom"}})

      path = temp_file("binary-ish", ".docx")

      assert {:ok, "custom from path"} = Parser.parse(path)
    end

    test "extensions are normalized (case and missing dot)" do
      put_arcana_env(:file_parsers, %{"DOCX" => FakeDocxParser})

      path = temp_file("x", ".docx")

      assert {:ok, "docx from path"} = Parser.parse(path)
    end

    test "a registered parser overrides a built-in format" do
      put_arcana_env(:file_parsers, %{".txt" => {FakeDocxParser, label: "override"}})

      path = temp_file("plain text", ".txt")

      assert {:ok, "override from path"} = Parser.parse(path)
    end

    test "supported_formats includes registered extensions" do
      put_arcana_env(:file_parsers, %{".docx" => FakeDocxParser})

      formats = Parser.supported_formats()

      assert ".docx" in formats
      assert ".txt" in formats
      assert ".pdf" in formats
    end
  end

  describe "fallback parser" do
    test "handles extensions nothing else claims" do
      put_arcana_env(:fallback_parser, {FakeDocxParser, label: "fallback"})

      path = temp_file("x", ".rtf")

      assert {:ok, "fallback from path"} = Parser.parse(path)
    end

    test "does not shadow native or registered formats" do
      put_arcana_env(:fallback_parser, {FakeDocxParser, label: "fallback"})

      path = temp_file("plain text", ".txt")

      assert {:ok, "plain text"} = Parser.parse(path)
    end

    test "without a fallback, unknown extensions are unsupported" do
      path = temp_file("x", ".rtf")

      assert {:error, :unsupported_format} = Parser.parse(path)
    end
  end

  describe "parse_binary/3" do
    test "routes binaries through a binary-capable parser" do
      put_arcana_env(:file_parsers, %{".docx" => FakeDocxParser})

      assert {:ok, "docx from binary", %{}} = Parser.parse_binary("raw bytes", "report.docx")
    end

    test "native text formats accept binaries directly" do
      assert {:ok, "hello", %{}} = Parser.parse_binary("hello", "notes.md")
    end

    test "a path-only parser refuses binary content" do
      put_arcana_env(:file_parsers, %{".docx" => PathOnlyParser})

      assert {:error, {:binary_unsupported, PathOnlyParser}} =
               Parser.parse_binary("raw", "report.docx")
    end

    test "unknown extensions are unsupported" do
      assert {:error, :unsupported_format} = Parser.parse_binary("raw", "report.rtf")
    end
  end

  describe "positional metadata" do
    test "parsers may return page metadata" do
      put_arcana_env(:file_parsers, %{".paged" => PagedParser})

      assert {:ok, "page one\npage two", %{pages: [%{number: 1}]}} =
               Parser.parse_binary("raw", "doc.paged")
    end

    test "parsers returning plain text get empty metadata" do
      put_arcana_env(:file_parsers, %{".docx" => FakeDocxParser})

      assert {:ok, _text, %{}} = Parser.parse_binary("raw", "doc.docx")
    end

    test "parse/1 keeps the two-tuple shape for existing callers" do
      put_arcana_env(:file_parsers, %{".paged" => PagedParser})

      path = temp_file("x", ".paged")

      assert {:ok, "page one\npage two"} = Parser.parse(path)
    end
  end

  describe "available?/1" do
    test "reports a parser's availability and true for native formats" do
      put_arcana_env(:file_parsers, %{".broken" => UnavailableParser, ".docx" => FakeDocxParser})

      refute Parser.available?(".broken")
      assert Parser.available?(".docx")
      assert Parser.available?(".txt")
    end

    test "is false for extensions nothing handles" do
      refute Parser.available?(".rtf")
    end
  end

  describe "content_type_for/1" do
    test "covers native formats and registered declarations" do
      put_arcana_env(:file_parsers, %{
        ".docx" =>
          {FakeDocxParser,
           content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
      })

      assert Parser.content_type_for("a.txt") == "text/plain"
      assert Parser.content_type_for("a.md") == "text/markdown"
      assert Parser.content_type_for("a.pdf") == "application/pdf"

      assert Parser.content_type_for("a.docx") ==
               "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

      assert Parser.content_type_for("a.rtf") == "application/octet-stream"
    end
  end
end
