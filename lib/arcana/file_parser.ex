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
  those extensions explicitly. Registering one as `false` disables it
  outright, fallback included.

  ## Implementing a parser

      defmodule MyApp.DocxParser do
        @behaviour Arcana.FileParser

        @impl true
        def parse(path_or_binary, opts) do
          {:ok, extracted_text}
        end

        # Optional: accept binary content, enabling `Arcana.ingest_binary/2`
        # for this format (default: false, path only). Path-only parsers
        # make ingest_binary/2 return {:error, {:binary_unsupported, mod}},
        # unless they are unavailable too — then unavailability is what
        # gets reported, since a path retry would fail just the same.
        @impl true
        def supports_binary?, do: true

        # Optional: report whether the parser can run right now, e.g. a
        # required CLI is installed (default: true). A parser reporting
        # `false` is not invoked at all: parsing returns
        # `{:error, {:parser_unavailable, module}}`.
        @impl true
        def available?, do: true
      end

  The gate lives in `parse/3`, so every dispatch path gets it: this
  module, `Arcana.FileParser.PDF.parse/3`, and everything routed through
  `Arcana.Parser`. The one exception to the error shape is the built-in
  `Arcana.FileParser.PDF.Poppler`, which reports `:poppler_not_available`
  for backwards compatibility — see `unavailable_reason/1`.

  ## Positional metadata

  `parse/2` may return `{:ok, text, meta}` instead of `{:ok, text}`.
  Arcana understands `%{pages: [%{number: 1, start: 0, end: 1234}, ...]}`,
  where the offsets are byte positions **in the returned text**. Parsers
  that don't know about pages return `{:ok, text}` as before.

  During ingestion Arcana intersects those ranges with each chunk's own
  byte range and stores the result as `"page_start"`/`"page_end"` in the
  chunk's metadata, where `Arcana.search/2` surfaces it:

      {:ok, _doc} = Arcana.ingest_file("manual.pdf", repo: Repo)

      [result | _] = Arcana.search("warranty", repo: Repo)
      result.metadata["page_start"]
      #=> 12

  A chunk straddling a page break reports the two different pages.
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

  Metadata that isn't a map, or whose `:pages` aren't
  `%{number: _, start: integer, end: integer}` maps, comes back as
  `{:error, {:invalid_parser_metadata, module, meta}}`. Ingestion reads
  those offsets long after the document row is inserted, so catching the
  shape here is what keeps a misbehaving parser from raising out of
  library internals and orphaning a `:processing` document.

  A parser reporting itself unavailable (`available?/0`) is never
  invoked: this returns `{:error, unavailable_reason(parser)}` instead.
  The check lives here rather than in a caller so that every route into
  a parser carries the same guarantee.
  """
  def parse({_module, _parser_opts} = parser, input, call_opts \\ []) do
    if available?(parser) do
      invoke(parser, input, call_opts)
    else
      {:error, unavailable_reason(parser)}
    end
  end

  defp invoke({module, parser_opts}, input, call_opts) do
    opts = Keyword.merge(parser_opts, call_opts)

    case module.parse(input, opts) do
      {:ok, text} ->
        {:ok, text, %{}}

      {:ok, text, meta} when is_map(meta) ->
        if valid_pages?(Map.get(meta, :pages)) do
          {:ok, text, meta}
        else
          {:error, {:invalid_parser_metadata, module, meta}}
        end

      # Metadata is documented as a map (`%{pages: [...]}`); a keyword list
      # is the easy slip. Report it rather than raising CaseClauseError from
      # inside the library with no hint of which parser misbehaved.
      {:ok, _text, meta} ->
        {:error, {:invalid_parser_metadata, module, meta}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_parser_return, module, other}}
    end
  end

  # `:pages` is the one metadata key ingestion reads, and it reads it deep
  # inside chunking — after the document row exists. String-keyed entries
  # (`%{"start" => 0}`) or bare numbers (`[1, 2]`) raise KeyError/BadMapError
  # from there, leaving a `:processing` document behind and naming no
  # parser. Checking the shape here keeps a bad parser to an error tuple
  # that says which module it was, before anything is written.
  #
  # Absent or empty pages are fine: those mean "this parser doesn't report
  # positions", which is the documented default.
  defp valid_pages?(nil), do: true
  defp valid_pages?(pages) when is_list(pages), do: Enum.all?(pages, &valid_page?/1)
  defp valid_pages?(_pages), do: false

  # A negative or reversed range is as malformed as a missing key, and it
  # fails worse: page_at/2 would fall back rather than raise, so the chunk
  # gets a page citation pointing somewhere the text isn't.
  defp valid_page?(%{number: _number, start: start_byte, end: end_byte})
       when is_integer(start_byte) and is_integer(end_byte) and
              start_byte >= 0 and end_byte >= start_byte,
       do: true

  defp valid_page?(_page), do: false

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

  Defaults to `true` for parsers that don't implement `available?/0`, but
  a module that can't be loaded (a typo in config) or doesn't implement
  `parse/2` is never available: reporting `true` there only postpones the
  failure to an `UndefinedFunctionError` at parse time.
  """
  def available?({module, _opts}) do
    cond do
      not match?({:module, _}, Code.ensure_loaded(module)) -> false
      not function_exported?(module, :parse, 2) -> false
      function_exported?(module, :available?, 0) -> module.available?()
      true -> true
    end
  end

  @doc """
  The error reported for a parser that can't run.

  `{:parser_unavailable, module}` for every parser but the built-in
  Poppler one, which has reported `:poppler_not_available` since before
  this gate existed and whose callers match on it.

  Callers that decide between several failure reasons (`Arcana.Parser`
  weighing this against `:binary_unsupported`, say) need the reason
  without invoking the parser, which is why this is public.
  """
  def unavailable_reason({Arcana.FileParser.PDF.Poppler, _opts}), do: :poppler_not_available
  def unavailable_reason({module, _opts}), do: {:parser_unavailable, module}
end
