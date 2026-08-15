defmodule Arcana.FileParser.PDF.PopplerTest do
  use ExUnit.Case, async: true

  alias Arcana.FileParser.PDF
  alias Arcana.FileParser.PDF.Poppler

  describe "available?/0" do
    test "returns boolean indicating pdftotext availability" do
      result = Poppler.available?()
      assert is_boolean(result)
    end
  end

  describe "supports_binary?/0" do
    test "returns false (poppler requires file path)" do
      refute Poppler.supports_binary?()
    end
  end

  describe "parse/2" do
    @describetag :pdf_support

    test "extracts text from PDF file" do
      if Poppler.available?() do
        path = fixture_path("sample.pdf")

        assert {:ok, text, _meta} = Poppler.parse(path, [])
        assert String.contains?(text, "Hello PDF")
      end
    end

    test "returns error for non-existent file" do
      if Poppler.available?() do
        assert {:error, :file_not_found} = Poppler.parse("/nonexistent/file.pdf", [])
      end
    end

    test "returns poppler_not_available when pdftotext missing" do
      # Can only truly test this in environments without poppler
      # but we verify the function exists and returns expected format
      path = fixture_path("sample.pdf")

      case Poppler.parse(path, []) do
        {:ok, _text, _meta} -> assert Poppler.available?()
        {:error, :poppler_not_available} -> refute Poppler.available?()
        {:error, {:pdftotext_failed, _}} -> :ok
        {:error, other} -> flunk("Unexpected error: #{inspect(other)}")
      end
    end

    test "respects layout option" do
      if Poppler.available?() do
        path = fixture_path("sample.pdf")

        # Both should succeed, layout just affects formatting
        assert {:ok, _text1, _meta1} = Poppler.parse(path, layout: true)
        assert {:ok, _text2, _meta2} = Poppler.parse(path, layout: false)
      end
    end

    test "a one-page PDF reports exactly one page" do
      # pdftotext terminates every page with a form feed, so a naive
      # split reported a phantom empty page N+1. The hand-written
      # page_ranges/2 fixtures below can't catch that: they have no
      # trailing form feed. Only the real tool's output does.
      if Poppler.available?() do
        assert {:ok, text, %{pages: pages}} = Poppler.parse(fixture_path("sample.pdf"), [])

        assert [%{number: 1, start: 0, end: page_end}] = pages
        assert page_end == byte_size(text)
        assert binary_part(text, 0, page_end) == text
      end
    end

    test "PDF.parse/3 still hands legacy callers a two-tuple" do
      if Poppler.available?() do
        parser = {Poppler, []}

        assert {:ok, text} = PDF.parse(parser, fixture_path("sample.pdf"))
        assert String.contains?(text, "Hello PDF")
      end
    end
  end

  defp fixture_path(filename) do
    Path.join([__DIR__, "..", "..", "..", "fixtures", filename])
  end

  describe "page_ranges/2" do
    test "derives page byte ranges from form feeds" do
      text = "page one\fpage two\fpage three"

      assert [
               %{number: 1, start: 0, end: 8},
               %{number: 2, start: 9, end: 17},
               %{number: 3, start: 18, end: 28}
             ] = Poppler.page_ranges(text, String.trim(text))

      # each range slices back to its page's text
      for %{start: s, end: e} <- Poppler.page_ranges(text, String.trim(text)) do
        assert binary_part(text, s, e - s) in ["page one", "page two", "page three"]
      end
    end

    test "single-page text is one range covering everything" do
      text = "just one page"

      assert [%{number: 1, start: 0, end: 13}] = Poppler.page_ranges(text, String.trim(text))
    end

    test "the trailing form feed pdftotext emits is not a page" do
      # Real pdftotext output terminates each page with \f, so two pages
      # arrive as "one\ftwo\f" — splitting that naively yields a third,
      # empty page.
      raw = "page one\fpage two\f"

      assert [%{number: 1}, %{number: 2}] = Poppler.page_ranges(raw, String.trim(raw))
    end

    test "a genuinely blank final page still gets its own range" do
      # A blank page 3 arrives as its own (empty) segment before the
      # terminating form feed, so it must survive the trailing-\f trim.
      raw = "page one\fpage two\f\f"

      assert [%{number: 1}, %{number: 2}, %{number: 3, start: s, end: e}] =
               Poppler.page_ranges(raw, String.trim(raw))

      assert s == e
    end

    test "blank leading pages keep their numbers and report empty ranges" do
      # pdftotext emits a form feed per page boundary; two blank pages up
      # front would otherwise be trimmed away, renumbering everything
      raw = "\f\fpage three text"
      trimmed = String.trim(raw)

      assert [
               %{number: 1, start: 0, end: 0},
               %{number: 2, start: 0, end: 0},
               %{number: 3, start: 0, end: 15}
             ] = Poppler.page_ranges(raw, trimmed)

      assert binary_part(trimmed, 0, 15) == "page three text"
    end
  end
end
