defmodule Arcana.Chunker do
  @moduledoc """
  Splits text into overlapping chunks using recursive character splitting.
  """

  @default_chunk_size 1024
  @default_chunk_overlap 200
  @separators ["\n\n", "\n", ". ", " ", ""]

  @doc """
  Splits text into chunks.

  Returns a list of maps with :text, :chunk_index, and :token_count.

  ## Options

    * `:chunk_size` - Maximum chunk size in characters (default: 1024)
    * `:chunk_overlap` - Overlap between chunks (default: 200)

  """
  def chunk(text, opts \\ [])

  def chunk("", _opts), do: []

  def chunk(text, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    _chunk_overlap = Keyword.get(opts, :chunk_overlap, @default_chunk_overlap)

    text
    |> recursive_split(@separators, chunk_size)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.with_index()
    |> Enum.map(fn {text, index} ->
      %{
        text: text,
        chunk_index: index,
        token_count: estimate_tokens(text)
      }
    end)
  end

  defp recursive_split(text, [], _chunk_size), do: [text]

  defp recursive_split(text, _separators, chunk_size) when byte_size(text) <= chunk_size do
    [text]
  end

  defp recursive_split(text, [sep | rest_seps], chunk_size) do
    parts = String.split(text, sep, trim: true)

    if length(parts) > 1 do
      parts
      |> Enum.flat_map(&recursive_split(&1, rest_seps, chunk_size))
      |> merge_small_chunks(chunk_size, sep)
    else
      recursive_split(text, rest_seps, chunk_size)
    end
  end

  defp merge_small_chunks(chunks, chunk_size, sep) do
    chunks
    |> Enum.reduce([], &merge_chunk(&1, &2, chunk_size, sep))
    |> Enum.reverse()
  end

  defp merge_chunk(chunk, [], _chunk_size, _sep), do: [chunk]

  defp merge_chunk(chunk, [last | rest] = acc, chunk_size, sep) do
    merged = last <> sep <> chunk

    if String.length(merged) <= chunk_size do
      [merged | rest]
    else
      [chunk | acc]
    end
  end

  defp estimate_tokens(text) do
    # Rough estimate: ~4 chars per token for English
    div(String.length(text), 4)
  end
end
