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

defmodule MustNotRunParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: raise("MustNotRunParser.parse/2 must not be invoked")

  @impl true
  def supports_binary?, do: true

  @impl true
  def available?, do: false
end

defmodule KeywordMetaParser do
  @moduledoc false
  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: {:ok, "text", pages: []}

  @impl true
  def supports_binary?, do: true
end

defmodule NotAParserAtAll do
  @moduledoc false
end

defmodule Arcana.FileParserRegistryTest do
  use Arcana.DataCase, async: true

  alias Arcana.FileParser
  alias Arcana.FileParser.PDF
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

    test "false disables the fallback instead of being treated as a module" do
      # `false` is an atom, so it used to sail through as a module name
      # and blow up with `function false.parse/2` at parse time
      put_arcana_env(:fallback_parser, false)

      assert Arcana.Config.fallback_parser() == nil

      path = temp_file("x", ".rtf")

      assert {:error, :unsupported_format} = Parser.parse(path)
    end

    test "a disabled fallback still leaves native formats alone" do
      put_arcana_env(:fallback_parser, false)

      path = temp_file("plain text", ".txt")

      assert {:ok, "plain text"} = Parser.parse(path)
    end

    test "a non-module fallback is a config error, not a runtime one" do
      put_arcana_env(:fallback_parser, true)

      assert_raise ArgumentError, ~r/invalid file parser config: true/, fn ->
        Arcana.Config.fallback_parser()
      end
    end

    test "a boolean or nil tuple head is a config error too" do
      # bare `false` was already rejected, but `{false, opts}` still looked
      # like a valid {module, opts} pair and reached `false.parse/2`
      put_arcana_env(:fallback_parser, {false, []})

      assert_raise ArgumentError, ~r/invalid file parser config: \{false, \[\]\}/, fn ->
        Arcana.Config.fallback_parser()
      end

      put_arcana_env(:fallback_parser, {nil, label: "x"})

      assert_raise ArgumentError, ~r/invalid file parser config: \{nil, /, fn ->
        Arcana.Config.fallback_parser()
      end
    end

    test "a boolean tuple head in :file_parsers is a config error, not a runtime crash" do
      put_arcana_env(:file_parsers, %{".docx" => {false, []}})

      path = temp_file("x", ".docx")

      assert_raise ArgumentError, ~r/invalid file parser config: \{false, \[\]\}/, fn ->
        Parser.parse(path)
      end
    end
  end

  describe "disabling an extension" do
    test "a file_parsers entry of false turns the extension off" do
      put_arcana_env(:file_parsers, %{".docx" => false})

      path = temp_file("x", ".docx")

      assert {:error, :unsupported_format} = Parser.parse(path)
      refute Parser.available?(".docx")
      refute ".docx" in Parser.supported_formats()
    end

    test "false beats the fallback parser, which would otherwise claim it" do
      put_arcana_env(:fallback_parser, {FakeDocxParser, label: "fallback"})
      put_arcana_env(:file_parsers, %{".docx" => false})

      path = temp_file("x", ".docx")

      assert {:error, :unsupported_format} = Parser.parse(path)
      assert {:error, :unsupported_format} = Parser.parse_binary("x", "a.docx")
    end

    test "false beats a built-in format too" do
      put_arcana_env(:file_parsers, %{".txt" => false})

      path = temp_file("plain text", ".txt")

      assert {:error, :unsupported_format} = Parser.parse(path)
      refute ".txt" in Parser.supported_formats()
      assert ".md" in Parser.supported_formats()
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

    test "a module that doesn't exist reports unavailable instead of defaulting to true" do
      put_arcana_env(:file_parsers, %{".docx" => MyApp.NoSuchParserWhatsoever})

      refute Parser.available?(".docx")
    end

    test "a module without parse/2 reports unavailable" do
      put_arcana_env(:file_parsers, %{".docx" => NotAParserAtAll})

      refute Parser.available?(".docx")
    end
  end

  describe "unavailable parsers" do
    test "an unavailable parser is never invoked" do
      put_arcana_env(:file_parsers, %{".docx" => MustNotRunParser})

      path = temp_file("x", ".docx")

      assert {:error, {:parser_unavailable, MustNotRunParser}} = Parser.parse(path)

      assert {:error, {:parser_unavailable, MustNotRunParser}} =
               Parser.parse_binary("x", "report.docx")
    end

    test "ingestion surfaces the unavailable parser instead of crashing" do
      put_arcana_env(:file_parsers, %{".docx" => MustNotRunParser})

      assert {:error, {:parser_unavailable, MustNotRunParser}} =
               Arcana.ingest_binary("x", filename: "report.docx", repo: Repo)
    end

    test "the public parser wrapper gates too, not just Arcana.Parser" do
      # FileParser.parse/3 is public API; callers reaching for it directly
      # got the parser invoked anyway, so the documented guarantee held
      # only for the Arcana.Parser route.
      assert {:error, {:parser_unavailable, MustNotRunParser}} =
               FileParser.parse({MustNotRunParser, []}, "raw bytes")
    end

    test "the PDF wrapper routes through the same gate" do
      assert {:error, {:parser_unavailable, MustNotRunParser}} =
               PDF.parse({MustNotRunParser, []}, "/tmp/whatever.pdf")
    end

    test "the built-in Poppler parser keeps reporting :poppler_not_available" do
      # Callers have matched on this bare atom since before the gate
      # existed. Every other parser gets the generic tuple.
      assert FileParser.unavailable_reason({PDF.Poppler, []}) == :poppler_not_available

      assert FileParser.unavailable_reason({MustNotRunParser, []}) ==
               {:parser_unavailable, MustNotRunParser}
    end

    test "an unavailable path-only parser reports unavailability, not binary_unsupported" do
      # Both conditions hold here: the supports_binary? short-circuit used
      # to answer first, so a caller matching {:parser_unavailable, _}
      # missed it on the binary path while catching it on the path one.
      put_arcana_env(:file_parsers, %{".docx" => UnavailableParser})

      assert {:error, {:parser_unavailable, UnavailableParser}} =
               Parser.parse_binary("raw", "report.docx")

      path = temp_file("x", ".docx")
      assert {:error, {:parser_unavailable, UnavailableParser}} = Parser.parse(path)
    end
  end

  describe "malformed parser returns" do
    test "a non-map third element is an error tuple, not a CaseClauseError" do
      put_arcana_env(:file_parsers, %{".docx" => KeywordMetaParser})

      assert {:error, {:invalid_parser_metadata, KeywordMetaParser, [pages: []]}} =
               Parser.parse_binary("raw", "doc.docx")
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
