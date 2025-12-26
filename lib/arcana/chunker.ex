defmodule Arcana.Chunker do
  @moduledoc """
  Splits text into overlapping chunks using text_chunker library.

  Supports multiple formats (plaintext, markdown, etc.) and can size chunks
  by characters or tokens.
  """

  @default_chunk_size 450  # Safe buffer under 512 model max
  @default_chunk_overlap 50
  @default_format :plaintext
  @default_size_unit :tokens

  @doc """
  Splits text into chunks.

  Returns a list of maps with :text, :chunk_index, and :token_count.

  ## Options

    * `:chunk_size` - Maximum chunk size (default: 512)
    * `:chunk_overlap` - Overlap between chunks (default: 50)
    * `:format` - Text format: `:plaintext`, `:markdown`, `:elixir`, etc. (default: :plaintext)
    * `:size_unit` - How to measure size: `:characters` or `:tokens` (default: :tokens)

  ## Examples

      Chunker.chunk("Hello world", chunk_size: 100)
      Chunker.chunk(markdown_text, format: :markdown, chunk_size: 512)
      Chunker.chunk(text, size_unit: :tokens, chunk_size: 256)

  """
  def chunk(text, opts \\ [])

  def chunk("", _opts), do: []

  def chunk(text, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    chunk_overlap = Keyword.get(opts, :chunk_overlap, @default_chunk_overlap)
    format = Keyword.get(opts, :format, @default_format)
    size_unit = Keyword.get(opts, :size_unit, @default_size_unit)

    # Convert token-based sizes to character-based for text_chunker
    # (text_chunker's merge logic doesn't use get_chunk_size properly)
    {effective_chunk_size, effective_overlap} =
      case size_unit do
        :tokens -> {chunk_size * 4, chunk_overlap * 4}
        :characters -> {chunk_size, chunk_overlap}
      end

    text_chunker_opts = [
      chunk_size: effective_chunk_size,
      chunk_overlap: effective_overlap,
      format: format
    ]

    text
    |> TextChunker.split(text_chunker_opts)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{
        text: chunk.text,
        chunk_index: index,
        token_count: estimate_tokens(chunk.text)
      }
    end)
  end

  defp estimate_tokens(text) do
    # Rough estimate: ~4 chars per token for English
    # This matches typical BPE tokenizer behavior
    max(1, div(String.length(text), 4))
  end
end
