defmodule Arcana.Parser do
  @moduledoc """
  Parses files into text content for ingestion.

  Supports multiple file formats including plain text, markdown, and PDF.
  """

  @text_extensions [".txt", ".md", ".markdown"]
  @pdf_extensions [".pdf"]

  @doc """
  Returns list of supported file extensions.
  """
  def supported_formats do
    @text_extensions ++ @pdf_extensions
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
    # Try pdftotext (poppler-utils) first
    case System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true) do
      {text, 0} ->
        {:ok, String.trim(text)}

      {_, _} ->
        {:error, :parse_error}
    end
  rescue
    ErlangError ->
      {:error, :pdftotext_not_found}
  end
end
