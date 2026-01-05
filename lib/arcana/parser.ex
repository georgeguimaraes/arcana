defmodule Arcana.Parser do
  @moduledoc """
  Parses files into text content for ingestion.

  Supports multiple file formats including plain text, markdown, and PDF.

  ## PDF Support

  PDF parsing is handled by a configurable parser. The default uses
  `pdftotext` from the Poppler library. See `Arcana.FileParser.PDF` for
  implementing custom PDF parsers.

  ### Default Parser (Poppler)

  The default PDF parser requires `pdftotext` to be installed:

      # macOS
      brew install poppler

      # Ubuntu/Debian
      apt-get install poppler-utils

      # Fedora
      dnf install poppler-utils

  ### Custom PDF Parser

  Configure a custom parser in `config.exs`:

      config :arcana, pdf_parser: MyApp.PDFParser

  See `Arcana.FileParser.PDF` for the behaviour specification.
  """

  alias Arcana.FileParser

  @text_extensions [".txt", ".md", ".markdown"]
  @pdf_extensions [".pdf"]

  @doc """
  Returns list of supported file extensions.
  """
  def supported_formats do
    @text_extensions ++ @pdf_extensions
  end

  @doc """
  Checks if PDF support is available.

  For the default Poppler parser, this checks if `pdftotext` is installed.
  Custom parsers may have different availability requirements.

  ## Examples

      iex> Arcana.Parser.pdf_support_available?()
      true  # or false if parser not available

  """
  def pdf_support_available? do
    {module, _opts} = Arcana.Config.pdf_parser()

    if function_exported?(module, :available?, 0) do
      module.available?()
    else
      true
    end
  end

  @doc """
  Parses a file and extracts text content.

  Returns `{:ok, text}` on success, or `{:error, reason}` on failure.
  """
  def parse(path) do
    cond do
      not File.exists?(path) ->
        {:error, :file_not_found}

      text_file?(path) ->
        parse_text_file(path)

      pdf_file?(path) ->
        parse_pdf(path)

      true ->
        {:error, :unsupported_format}
    end
  end

  defp text_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @text_extensions
  end

  defp pdf_file?(path) do
    ext = Path.extname(path) |> String.downcase()
    ext in @pdf_extensions
  end

  defp parse_text_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :read_error}
    end
  end

  defp parse_pdf(path) do
    # First verify it's a valid PDF by checking magic bytes
    case File.read(path) do
      {:ok, content} ->
        if String.starts_with?(content, "%PDF") do
          extract_pdf_text(path)
        else
          {:error, :invalid_pdf}
        end

      {:error, _} ->
        {:error, :read_error}
    end
  end

  defp extract_pdf_text(path) do
    pdf_parser = Arcana.Config.pdf_parser()
    FileParser.PDF.parse(pdf_parser, path)
  end
end
