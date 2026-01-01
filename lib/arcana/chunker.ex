defmodule Arcana.Chunker do
  @moduledoc """
  Behaviour for text chunking providers used by Arcana.

  Arcana accepts any module that implements this behaviour.
  Built-in implementations are provided for:

  - `Arcana.Chunker.Default` - Default chunking using text_chunker library

  ## Configuration

  Configure your chunking provider in `config.exs`:

      # Default: text_chunker-based chunking
      config :arcana, chunker: :default

      # Default chunker with custom options
      config :arcana, chunker: {:default, chunk_size: 512, chunk_overlap: 100}

      # Custom function
      config :arcana, chunker: fn text, opts -> [%{text: text, chunk_index: 0, token_count: 10}] end

      # Custom module implementing this behaviour
      config :arcana, chunker: MyApp.SemanticChunker
      config :arcana, chunker: {MyApp.SemanticChunker, model: "..."}

  ## Implementing a Custom Chunker

  Create a module that implements this behaviour:

      defmodule MyApp.SemanticChunker do
        @behaviour Arcana.Chunker

        @impl true
        def chunk(text, opts) do
          # Custom chunking logic...
          # Return list of chunk maps
          [
            %{text: "chunk 1", chunk_index: 0, token_count: 50},
            %{text: "chunk 2", chunk_index: 1, token_count: 45}
          ]
        end
      end

  Then configure:

      config :arcana, chunker: {MyApp.SemanticChunker, model: "..."}

  ## Chunk Format

  Each chunk returned must be a map with at minimum:

    * `:text` - The chunk text content (required)
    * `:chunk_index` - Zero-based index of this chunk (required)
    * `:token_count` - Estimated token count (required)

  Additional keys may be included and will be passed through to storage.
  """

  @type chunk :: %{
          required(:text) => String.t(),
          required(:chunk_index) => non_neg_integer(),
          required(:token_count) => pos_integer()
        }

  @doc """
  Splits text into chunks.

  Returns a list of chunk maps, each containing at minimum `:text`,
  `:chunk_index`, and `:token_count`.

  ## Options

  Options are implementation-specific. Common options include:

    * `:chunk_size` - Maximum chunk size
    * `:chunk_overlap` - Overlap between chunks
    * `:format` - Text format hint (`:plaintext`, `:markdown`, etc.)

  """
  @callback chunk(text :: String.t(), opts :: keyword()) :: [chunk()]

  @doc """
  Chunks text using the configured chunker.

  The chunker is a `{module, opts}` tuple where module implements
  this behaviour.
  """
  def chunk({module, opts}, text) when is_atom(module) do
    module.chunk(text, opts)
  end

  @doc """
  Chunks text using the configured chunker, merging additional options.

  Useful when you need to override chunker defaults at call time.
  """
  def chunk({module, default_opts}, text, extra_opts) when is_atom(module) do
    merged_opts = Keyword.merge(default_opts, extra_opts)
    module.chunk(text, merged_opts)
  end
end
