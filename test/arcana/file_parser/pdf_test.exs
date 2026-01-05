defmodule Arcana.FileParser.PDFTest do
  use ExUnit.Case, async: true

  alias Arcana.FileParser.PDF

  describe "parse/3" do
    test "delegates to configured parser module" do
      parser = {Arcana.FileParser.PDF.Poppler, []}

      if Arcana.FileParser.PDF.Poppler.available?() do
        path = fixture_path("sample.pdf")
        assert {:ok, text} = PDF.parse(parser, path)
        assert String.contains?(text, "Hello PDF")
      end
    end

    test "merges call options with parser options" do
      parser = {Arcana.FileParser.PDF.Poppler, [layout: true]}

      if Arcana.FileParser.PDF.Poppler.available?() do
        path = fixture_path("sample.pdf")
        # Override layout option
        assert {:ok, _text} = PDF.parse(parser, path, layout: false)
      end
    end
  end

  describe "supports_binary?/1" do
    test "returns false for Poppler parser" do
      parser = {Arcana.FileParser.PDF.Poppler, []}
      refute PDF.supports_binary?(parser)
    end
  end

  defp fixture_path(filename) do
    Path.join([__DIR__, "..", "..", "fixtures", filename])
  end
end
