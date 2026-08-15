defmodule Arcana.FileParser.PDF.Poppler do
  @moduledoc """
  PDF parser using poppler's `pdftotext` command.

  This is the default PDF parser for Arcana. It requires the `pdftotext`
  command from the Poppler library to be installed on the system.

  ## Installation

      # macOS
      brew install poppler

      # Ubuntu/Debian
      apt-get install poppler-utils

      # Fedora
      dnf install poppler-utils

  ## Options

    * `:layout` - Preserve original text layout (default: true)

  """

  @behaviour Arcana.FileParser.PDF

  @doc """
  Checks if `pdftotext` is available on the system.

  ## Examples

      iex> Arcana.FileParser.PDF.Poppler.available?()
      true  # or false if poppler not installed

  """
  def available? do
    case System.find_executable("pdftotext") do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Returns false - Poppler requires a file path, not binary content.
  """
  def supports_binary?, do: false

  @impl true
  def parse(path, opts) when is_binary(path) do
    cond do
      not available?() -> {:error, :poppler_not_available}
      not File.exists?(path) -> {:error, :file_not_found}
      true -> extract_text(path, opts)
    end
  end

  defp extract_text(path, opts) do
    layout = Keyword.get(opts, :layout, true)
    args = build_args(path, layout)

    case System.cmd("pdftotext", args, stderr_to_stdout: true) do
      {text, 0} ->
        trimmed = String.trim(text)
        {:ok, trimmed, %{pages: page_ranges(text, trimmed)}}

      {error_output, _code} ->
        {:error, {:pdftotext_failed, error_output}}
    end
  end

  # pdftotext separates pages with a form feed. Page ranges are computed
  # from the raw output so blank leading/trailing pages keep their
  # numbers, then shifted into the trimmed text that callers receive; a
  # page that trimming removed entirely reports an empty range rather
  # than disappearing and renumbering the pages after it.
  @doc false
  def page_ranges(raw, trimmed) do
    leading = byte_size(raw) - byte_size(String.trim_leading(raw))
    limit = byte_size(trimmed)

    raw
    |> String.split("\f")
    |> Enum.reduce({[], 0, 1}, fn page, {acc, offset, number} ->
      raw_end = offset + byte_size(page)

      page_start = offset |> Kernel.-(leading) |> clamp(limit)
      page_end = raw_end |> Kernel.-(leading) |> clamp(limit)

      # +1 skips the form feed separating this page from the next
      {[%{number: number, start: page_start, end: page_end} | acc], raw_end + 1, number + 1}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp clamp(value, limit), do: value |> max(0) |> min(limit)

  defp build_args(path, layout) do
    base_args = if layout, do: ["-layout"], else: []
    base_args ++ [path, "-"]
  end
end
