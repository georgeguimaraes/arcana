defmodule Arcana.Chunker.Default do
  @moduledoc """
  Default text chunker using the text_chunker library.

  Supports multiple formats (plaintext, markdown, etc.) and can size chunks
  by characters or tokens.

  ## Options

    * `:chunk_size` - Maximum chunk size (default: 450)
    * `:chunk_overlap` - Overlap between chunks (default: 50)
    * `:format` - Text format: `:plaintext`, `:markdown`, `:elixir`, etc. (default: :plaintext)
    * `:size_unit` - How to measure size: `:characters` or `:tokens` (default: :tokens)
    * `:chars_per_token` - Characters assumed per token when `size_unit` is
      `:tokens` (default: 4). A positive integer; anything else raises an
      `ArgumentError`
    * `:max_chunk_chars` - Ceiling on a chunk's length in bytes. A chunk over
      it is split rather than emitted (default: none). Splits land on
      grapheme boundaries, so a single grapheme longer than the budget - a
      ZWJ emoji sequence runs to 25 bytes - is emitted whole rather than
      cut into invalid UTF-8. Any budget worth setting is far above that.
      A positive integer or `nil`; anything else raises an `ArgumentError`

  ## Sizing by tokens is an estimate, not a guarantee

  With `size_unit: :tokens` the size is converted to characters by
  multiplying by `:chars_per_token`, which defaults to 4. That is a fair
  average for flowing English prose and **not an upper bound**. Dense text
  runs closer to 3 characters per token, and tables of numbers can approach
  2, so the default 450 tokens can produce chunks an embedder with a 512
  token window rejects:

      413 Input validation error: 'inputs' must have less than 512 tokens. Given: 573

  Nothing here can tell you that has happened, because the chunker does not
  run the model's tokenizer. Two ways to stay inside the budget:

    * lower `:chars_per_token` for a corpus you know is dense — product data
      sheets, code, chemical names, digit-heavy tables
    * set `:max_chunk_chars` as a backstop, so a pathological chunk is split
      instead of being handed to the embedder oversized

  Remember any prefix your embedder adds (E5-style `passage: ` / `query: `)
  comes out of the same budget.

  ## Examples

      Arcana.Chunker.Default.chunk("Hello world", chunk_size: 100)
      Arcana.Chunker.Default.chunk(markdown_text, format: :markdown, chunk_size: 512)
      Arcana.Chunker.Default.chunk(text, size_unit: :tokens, chunk_size: 256)

  """

  @behaviour Arcana.Chunker

  # Safe buffer under 512 model max, assuming @default_chars_per_token.
  # Dense text breaks that assumption: see the moduledoc.
  @default_chunk_size 450
  @default_chunk_overlap 50
  @default_format :plaintext
  @default_size_unit :tokens
  @default_chars_per_token 4

  @impl true
  def chunk(text, opts \\ [])

  # Options are checked before the empty-text shortcut, so a bad value is
  # reported whatever the input happens to be.
  def chunk("", opts) do
    _ = sizing_opts(opts)
    []
  end

  def chunk(text, opts) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    chunk_overlap = Keyword.get(opts, :chunk_overlap, @default_chunk_overlap)
    format = Keyword.get(opts, :format, @default_format)
    size_unit = Keyword.get(opts, :size_unit, @default_size_unit)

    {chars_per_token, max_chunk_chars} = sizing_opts(opts)

    # Convert token-based sizes to character-based for text_chunker
    # (text_chunker's merge logic doesn't use get_chunk_size properly)
    {effective_chunk_size, effective_overlap} =
      case size_unit do
        :tokens -> {chunk_size * chars_per_token, chunk_overlap * chars_per_token}
        :characters -> {chunk_size, chunk_overlap}
      end

    validate_overlap!(effective_chunk_size, effective_overlap, chunk_size, chunk_overlap)

    text_chunker_opts = [
      chunk_size: effective_chunk_size,
      chunk_overlap: effective_overlap,
      format: format
    ]

    text
    |> TextChunker.split(text_chunker_opts)
    |> unwrap_split!()
    |> Enum.flat_map(&enforce_max_chars(&1, max_chunk_chars))
    |> Enum.reject(&blank?(&1.text))
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{
        text: chunk.text,
        chunk_index: index,
        token_count: estimate_tokens(chunk.text, chars_per_token),
        # Byte offsets into the source text, carried through to chunk
        # metadata so citations can point back at the original document.
        # chunk_index is renumbered after blanks are dropped, so offsets
        # are the only reliable position key.
        metadata: %{
          "start_byte" => chunk.start_byte,
          "end_byte" => chunk.end_byte
        }
      }
    end)
  end

  # An overlap larger than the chunk it overlaps is meaningless, and
  # text_chunker rejects it. Checking here names arcana's own options and
  # the unit they were given in, which the library can't do: with
  # `size_unit: :tokens` it only ever sees the character-converted values.
  defp validate_overlap!(size, overlap, raw_size, raw_overlap) when overlap > size do
    raise ArgumentError,
          ":chunk_overlap must not be greater than :chunk_size, got overlap " <>
            "#{inspect(raw_overlap)} and size #{inspect(raw_size)}. The default " <>
            "overlap is #{@default_chunk_overlap}, so a chunk_size below that " <>
            "needs an explicit chunk_overlap too."
  end

  defp validate_overlap!(_size, _overlap, _raw_size, _raw_overlap), do: :ok

  # text_chunker returns {:error, message} for an option combination it
  # refuses. Piping that into Enum blows up as a Protocol.UndefinedError
  # naming Enumerable and Tuple, which says nothing about what was wrong.
  defp unwrap_split!({:error, reason}) do
    raise ArgumentError, "text_chunker rejected these chunk options: #{reason}"
  end

  defp unwrap_split!(chunks) when is_list(chunks), do: chunks

  defp sizing_opts(opts) do
    chars_per_token =
      validate_positive!(
        :chars_per_token,
        Keyword.get(opts, :chars_per_token, @default_chars_per_token)
      )

    max_chunk_chars =
      case Keyword.get(opts, :max_chunk_chars) do
        nil -> nil
        value -> validate_positive!(:max_chunk_chars, value)
      end

    {chars_per_token, max_chunk_chars}
  end

  defp blank?(nil), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""

  # Both of these feed arithmetic - one a div/2, the other a byte budget -
  # so a zero or a non-integer surfaces far from the option that caused it:
  # chars_per_token: 0 came out as a Protocol.UndefinedError, and
  # max_chunk_chars: 0 silently returned one grapheme per chunk.
  defp validate_positive!(_key, value) when is_integer(value) and value > 0, do: value

  defp validate_positive!(key, value) do
    raise ArgumentError,
          "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
  end

  # text_chunker sizes by its own rules and can still emit a chunk longer
  # than asked for. Splitting on bytes keeps start_byte/end_byte meaningful,
  # and the split lands on a codepoint boundary so the text stays valid.
  defp enforce_max_chars(chunk, nil), do: [chunk]

  defp enforce_max_chars(chunk, max_chars) when byte_size(chunk.text) <= max_chars, do: [chunk]

  defp enforce_max_chars(chunk, max_chars) do
    chunk.text
    |> split_on_byte_budget(max_chars)
    |> Enum.reduce({[], chunk.start_byte}, fn piece, {pieces, offset} ->
      finish = offset + byte_size(piece)
      {[%{chunk | text: piece, start_byte: offset, end_byte: finish} | pieces], finish}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp split_on_byte_budget(text, max_chars) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], [], 0}, fn grapheme, {done, current, size} ->
      grapheme_size = byte_size(grapheme)

      if size + grapheme_size > max_chars and current != [] do
        {[IO.iodata_to_binary(Enum.reverse(current)) | done], [grapheme], grapheme_size}
      else
        {done, [grapheme | current], size + grapheme_size}
      end
    end)
    |> then(fn {done, current, _size} ->
      done = if current == [], do: done, else: [IO.iodata_to_binary(Enum.reverse(current)) | done]
      Enum.reverse(done)
    end)
  end

  defp estimate_tokens(text, chars_per_token) do
    # An estimate, not a measurement: see the moduledoc on why this can
    # undercount dense text.
    max(1, div(String.length(text), chars_per_token))
  end
end
