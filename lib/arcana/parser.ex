defmodule Arcana.Parser do
  @moduledoc """
  Parses files into text content for ingestion.

  Plain text and markdown are read natively, PDFs go through a
  configurable parser (Poppler's `pdftotext` by default), and any other
  format is handled by a parser you register.

  ## Resolution order

  For a file's extension (lowercased, with a leading dot):

  1. an exact match in `config :arcana, :file_parsers` (a `false` entry
     means the extension is disabled and resolution stops here)
  2. the built-ins: `.txt`/`.md`/`.markdown` read natively, `.pdf` via
     `config :arcana, :pdf_parser`
  3. `config :arcana, :fallback_parser`, unless it is `nil`/`false`
  4. otherwise `{:error, :unsupported_format}`

  ## Registering parsers

      config :arcana,
        # per-format
        file_parsers: %{".docx" => {MyApp.DocxParser, []}},
        # everything else (e.g. an extraction service covering many formats)
        fallback_parser: {MyApp.ExtractionService, []}

  Registering `".pdf"` in `:file_parsers` overrides the built-in PDF
  route; registering it as `false` turns it off entirely, fallback
  included. See `Arcana.FileParser` for the behaviour.

  ## PDF Support

  The default PDF parser requires `pdftotext` to be installed:

      # macOS
      brew install poppler

      # Ubuntu/Debian
      apt-get install poppler-utils

      # Fedora
      dnf install poppler-utils

  """

  alias Arcana.{Config, FileParser}

  @text_extensions [".txt", ".md", ".markdown"]
  @pdf_extensions [".pdf"]

  @doc """
  Returns the list of supported file extensions.

  Includes the natively handled formats plus any registered through
  `:file_parsers`, minus any disabled with `false`. When a
  `:fallback_parser` is configured every extension is effectively
  supported, so this list is a lower bound.
  """
  def supported_formats do
    registered = Config.file_parsers()
    disabled = for {extension, nil} <- registered, do: extension

    (@text_extensions ++ @pdf_extensions ++ Map.keys(registered))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in disabled))
  end

  @doc """
  Checks if PDF support is available.

  For the default Poppler parser, this checks if `pdftotext` is installed.
  Custom parsers may have different availability requirements.

  ## Examples

      iex> Arcana.Parser.pdf_support_available?()
      true  # or false if parser not available

  """
  def pdf_support_available?, do: available?(".pdf")

  @doc """
  Whether the parser handling `extension` can run right now.

  Returns `false` when no parser handles the extension at all.
  """
  def available?(extension) do
    case resolve(extension) do
      {:ok, :native} -> true
      {:ok, parser} -> FileParser.available?(parser)
      {:error, _} -> false
    end
  end

  @doc """
  Parses a file and extracts text content.

  Returns `{:ok, text}` on success, or `{:error, reason}` on failure.
  Use `parse_file/2` to also receive positional metadata.
  """
  def parse(path) do
    case parse_file(path) do
      {:ok, text, _meta} -> {:ok, text}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses a file, returning text and any positional metadata the parser
  reported.

  Returns `{:ok, text, meta}` where `meta` is `%{}` for parsers that
  don't report positions. See `Arcana.FileParser` for the metadata shape.
  """
  def parse_file(path, opts \\ []) do
    extension = Path.extname(path)

    if File.exists?(path) do
      do_parse_file(path, extension, opts)
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Parses binary content, routing on `filename`'s extension.

  The resolved parser must accept binary input (`supports_binary?/0`),
  otherwise returns `{:error, {:binary_unsupported, module}}`. Natively
  handled text formats always work.

  When a parser is both unavailable (`available?/0`) and path-only,
  unavailability wins: this returns `{:error, {:parser_unavailable,
  module}}`, the same reason the path-based flow gives.
  """
  def parse_binary(binary, filename, opts \\ []) when is_binary(binary) do
    extension = Path.extname(filename)

    case resolve(extension) do
      {:ok, :native} ->
        {:ok, binary, %{}}

      {:ok, {module, _} = parser} ->
        cond do
          FileParser.supports_binary?(parser) ->
            validate_and_parse(binary, :binary, extension, parser, opts)

          # A parser that can't run won't handle a file path either, so
          # reporting :binary_unsupported would send the caller off to a
          # retry that fails just the same. Unavailability wins, keeping
          # this flow's reason identical to the path-based one.
          not FileParser.available?(parser) ->
            {:error, FileParser.unavailable_reason(parser)}

          true ->
            {:error, {:binary_unsupported, module}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the content type for a path or filename, based on its
  extension.

  Registered parsers may declare a `:content_type` in their options;
  otherwise unknown extensions report `application/octet-stream`.
  """
  def content_type_for(path) do
    extension = Config.normalize_extension(Path.extname(path))

    # A registered parser's declared type wins over the built-in default,
    # since registering an extension overrides its built-in route too.
    case resolve(extension) do
      {:ok, {_module, opts}} ->
        Keyword.get(opts, :content_type) || builtin_content_type(extension)

      _ ->
        builtin_content_type(extension)
    end
  end

  defp builtin_content_type(".txt"), do: "text/plain"
  defp builtin_content_type(ext) when ext in [".md", ".markdown"], do: "text/markdown"
  defp builtin_content_type(".pdf"), do: "application/pdf"
  defp builtin_content_type(_), do: "application/octet-stream"

  # Resolves an extension to :native, a {module, opts} parser, or an error.
  #
  # A registered entry always wins, including `%{".pdf" => false}`, which
  # arrives here as nil and means "disabled": it blocks the built-in route
  # and the fallback rather than quietly deferring to them.
  defp resolve(extension) do
    extension = Config.normalize_extension(extension)

    case Map.fetch(Config.file_parsers(), extension) do
      {:ok, nil} -> {:error, :unsupported_format}
      {:ok, parser} -> {:ok, parser}
      :error -> resolve_builtin(extension)
    end
  end

  defp resolve_builtin(extension) do
    cond do
      extension in @text_extensions -> {:ok, :native}
      extension in @pdf_extensions -> {:ok, Config.pdf_parser()}
      fallback = Config.fallback_parser() -> {:ok, fallback}
      true -> {:error, :unsupported_format}
    end
  end

  defp do_parse_file(path, extension, opts) do
    case resolve(extension) do
      {:ok, :native} ->
        case File.read(path) do
          {:ok, content} -> {:ok, content, %{}}
          {:error, _} -> {:error, :read_error}
        end

      {:ok, parser} ->
        validate_and_parse(path, :path, extension, parser, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # PDFs are magic-byte checked before reaching a parser, so a mislabeled
  # file fails with :invalid_pdf instead of whatever the tool reports.
  # `kind` says whether `input` is a path to read or the bytes themselves:
  # binary content that happens to look like a path must never be read
  # off disk.
  defp validate_and_parse(input, kind, extension, parser, opts) do
    if Config.normalize_extension(extension) in @pdf_extensions do
      case pdf_content(input, kind) do
        {:ok, content} ->
          if String.starts_with?(content, "%PDF") do
            FileParser.parse(parser, input, opts)
          else
            {:error, :invalid_pdf}
          end

        error ->
          error
      end
    else
      FileParser.parse(parser, input, opts)
    end
  end

  defp pdf_content(binary, :binary), do: {:ok, binary}

  defp pdf_content(path, :path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _} -> {:error, :read_error}
    end
  end
end
