defmodule Arcana.FileParser.PDF do
  @moduledoc """
  Behaviour for PDF parsing providers.

  Arcana accepts any module that implements this behaviour for PDF text extraction.
  The built-in implementation uses poppler's `pdftotext` command.

  ## Configuration

  Configure your PDF parser in `config.exs`:

      # Default: poppler's pdftotext
      config :arcana, pdf_parser: :poppler

      # Custom module implementing this behaviour
      config :arcana, pdf_parser: MyApp.PDFParser
      config :arcana, pdf_parser: {MyApp.PDFParser, some_option: "value"}

  ## Implementing a Custom PDF Parser

  Create a module that implements this behaviour:

      defmodule MyApp.PDFParser do
        @behaviour Arcana.FileParser.PDF

        @impl true
        def parse(path, opts) when is_binary(path) do
          # Parse PDF at file path
          {:ok, extracted_text}
        end

        # Optional: handle binary content directly
        def parse(binary, opts) when is_binary(binary) do
          # Parse PDF binary content
          {:ok, extracted_text}
        end
      end

  Then configure:

      config :arcana, pdf_parser: {MyApp.PDFParser, some_option: "value"}

  """

  @doc """
  Parses a PDF and extracts text content.

  The first argument can be either:
  - A file path (string) - the implementation reads the file
  - Binary content - the implementation parses directly

  Returns `{:ok, text}` on success, or `{:error, reason}` on failure.

  ## Options

  Options are implementation-specific. The default Poppler implementation
  supports:

    * `:layout` - Preserve original layout (default: true)

  """
  @callback parse(path_or_binary :: binary(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Parses a PDF using the configured parser.

  The parser is a `{module, opts}` tuple where module implements
  this behaviour.
  """
  def parse({module, opts}, path_or_binary, call_opts \\ []) when is_atom(module) do
    merged_opts = Keyword.merge(opts, call_opts)
    module.parse(path_or_binary, merged_opts)
  end

  @doc """
  Checks if the given parser module supports binary input.

  Some parsers (like Poppler) require a file path and don't support
  parsing binary content directly.
  """
  def supports_binary?({module, _opts}) when is_atom(module) do
    # Check if the module explicitly declares binary support
    # Default to false for safety
    if function_exported?(module, :supports_binary?, 0) do
      module.supports_binary?()
    else
      false
    end
  end
end
