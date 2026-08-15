defmodule Arcana.FileParser do
  @moduledoc """
  Behaviour for extracting text from files of any format.

  Arcana ships native handling for plain text and markdown, and a
  Poppler-backed PDF parser. Any other format works by registering a
  parser for its extension:

      config :arcana,
        file_parsers: %{
          ".docx" => {MyApp.DocxParser, endpoint: "http://extract.internal"}
        }

  A single parser can also handle everything Arcana doesn't natively
  support — useful for extraction services that cover many formats:

      config :arcana, fallback_parser: {MyApp.ExtractionService, []}

  Exact extension matches win over the fallback, and the built-in
  handling for `.txt`/`.md`/`.pdf` can be overridden by registering
  those extensions explicitly.

  ## Implementing a parser

      defmodule MyApp.DocxParser do
        @behaviour Arcana.FileParser

        @impl true
        def parse(path_or_binary, opts) do
          {:ok, extracted_text}
        end

        # Optional: accept binary content, enabling Arcana.ingest_binary/2
        # for this format (default: false, path only)
        @impl true
        def supports_binary?, do: true

        # Optional: report whether the parser can run right now, e.g. a
        # required CLI is installed (default: true)
        @impl true
        def available?, do: true
      end

  ## Positional metadata

  `parse/2` may return `{:ok, text, meta}` instead of `{:ok, text}`.
  Arcana understands `%{pages: [%{number: 1, start: 0, end: 1234}, ...]}`,
  where the offsets are byte positions **in the returned text**, and uses
  them to attach page numbers to chunks. Parsers that don't know about
  pages return `{:ok, text}` as before.
  """

  @type meta :: map()

  @callback parse(input :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:ok, String.t(), meta()} | {:error, term()}

  @callback supports_binary?() :: boolean()
  @callback available?() :: boolean()

  @optional_callbacks supports_binary?: 0, available?: 0

  @doc """
  Invokes a `{module, opts}` parser, normalizing its return to
  `{:ok, text, meta}`.

  Parsers predating positional metadata return `{:ok, text}`; those come
  back here as `{:ok, text, %{}}` so callers only handle one shape.
  """
  def parse({module, parser_opts}, input, call_opts \\ []) do
    opts = Keyword.merge(parser_opts, call_opts)

    case module.parse(input, opts) do
      {:ok, text} -> {:ok, text, %{}}
      {:ok, text, meta} when is_map(meta) -> {:ok, text, meta}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Whether a `{module, opts}` parser accepts binary content.

  Defaults to `false`: a parser that doesn't say otherwise is assumed to
  need a file path.
  """
  def supports_binary?({module, _opts}) do
    Code.ensure_loaded(module)
    function_exported?(module, :supports_binary?, 0) and module.supports_binary?()
  end

  @doc """
  Whether a `{module, opts}` parser can run right now.

  Defaults to `true` for parsers that don't implement `available?/0`.
  """
  def available?({module, _opts}) do
    Code.ensure_loaded(module)

    if function_exported?(module, :available?, 0) do
      module.available?()
    else
      true
    end
  end
end
