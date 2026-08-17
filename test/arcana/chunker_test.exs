defmodule Arcana.ChunkerTest do
  use ExUnit.Case, async: true

  alias Arcana.Chunker.Default, as: Chunker

  describe "chunk/2" do
    test "splits text into chunks of specified size" do
      # ~2500 chars
      text = String.duplicate("word ", 500)

      chunks = Chunker.chunk(text, chunk_size: 1024, size_unit: :characters)

      assert length(chunks) > 1
      assert Enum.all?(chunks, fn chunk -> String.length(chunk.text) <= 1024 end)
    end

    test "returns single chunk for small text" do
      text = "This is a short text."

      chunks = Chunker.chunk(text)

      assert length(chunks) == 1
      assert hd(chunks).text == text
    end

    test "includes chunk_index starting at 0" do
      text = String.duplicate("word ", 500)

      chunks = Chunker.chunk(text, chunk_size: 500, size_unit: :characters)

      indices = Enum.map(chunks, & &1.chunk_index)
      assert indices == Enum.to_list(0..(length(chunks) - 1))
    end

    test "estimates token count for each chunk" do
      text = "Hello world this is a test"

      [chunk] = Chunker.chunk(text)

      assert chunk.token_count > 0
      # Rough estimate: ~4 chars per token
      assert chunk.token_count == div(String.length(text), 4)
    end

    test "splits on paragraph boundaries when possible" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

      chunks = Chunker.chunk(text, chunk_size: 30, chunk_overlap: 5, size_unit: :characters)

      # Should split cleanly on \n\n
      assert Enum.any?(chunks, fn c -> c.text == "First paragraph." end)
    end

    test "handles empty text" do
      assert Chunker.chunk("") == []
    end

    test "filters out whitespace-only chunks" do
      # Text with lots of whitespace that could produce empty chunks
      text = "Content.\n\n\n\n\n\n\nMore content."

      chunks = Chunker.chunk(text, chunk_size: 20, chunk_overlap: 5, size_unit: :characters)

      # No chunk should be blank
      for chunk <- chunks do
        assert String.trim(chunk.text) != "", "Found blank chunk: #{inspect(chunk.text)}"
      end
    end

    test "accepts format option for plaintext" do
      text = "Hello world"
      chunks = Chunker.chunk(text, format: :plaintext)

      assert length(chunks) == 1
      assert hd(chunks).text == text
    end

    test "accepts format option for markdown" do
      text = "# Heading\n\nParagraph content here."
      chunks = Chunker.chunk(text, format: :markdown)

      refute Enum.empty?(chunks)
    end

    test "markdown format respects heading boundaries" do
      text = """
      # First Section

      Content for first section.

      # Second Section

      Content for second section.
      """

      chunks = Chunker.chunk(text, format: :markdown, chunk_size: 50)

      # Should not split in the middle of a section
      chunk_texts = Enum.map(chunks, & &1.text)
      assert Enum.any?(chunk_texts, &String.contains?(&1, "# First Section"))
    end

    test "size_unit :tokens counts tokens not characters" do
      # "hello world " = 12 chars but ~2-3 tokens
      # 50 repetitions = 600 chars, ~100-150 tokens
      text = String.duplicate("hello world ", 50)

      # With 100 tokens limit, should be 1-2 chunks
      # With 100 chars limit, would be 6+ chunks
      token_chunks = Chunker.chunk(text, chunk_size: 100, size_unit: :tokens)
      char_chunks = Chunker.chunk(text, chunk_size: 100, size_unit: :characters)

      # Token-based should have fewer chunks than char-based
      assert length(token_chunks) < length(char_chunks)
    end
  end

  describe "source offsets" do
    test "every chunk carries byte offsets that slice back to its text" do
      text =
        Enum.map_join(1..40, "\n\n", fn i ->
          "Paragraph #{i} with enough words to make the chunker split things up."
        end)

      chunks = Chunker.chunk(text, chunk_size: 60, chunk_overlap: 10)

      assert length(chunks) > 1

      for chunk <- chunks do
        start_byte = chunk.metadata["start_byte"]
        end_byte = chunk.metadata["end_byte"]

        assert is_integer(start_byte) and is_integer(end_byte)
        assert binary_part(text, start_byte, end_byte - start_byte) == chunk.text
      end
    end

    test "offsets stay correct when the same text repeats" do
      # A naive scan for chunk text would mislocate these; the offsets
      # come from the splitter itself
      paragraph = "The very same paragraph repeated verbatim several times over."
      text = Enum.map_join(1..12, "\n\n", fn _ -> paragraph end)

      chunks = Chunker.chunk(text, chunk_size: 40, chunk_overlap: 5)

      offsets = Enum.map(chunks, & &1.metadata["start_byte"])

      assert offsets == Enum.sort(offsets)
      assert length(Enum.uniq(offsets)) == length(offsets)

      for chunk <- chunks do
        start_byte = chunk.metadata["start_byte"]
        end_byte = chunk.metadata["end_byte"]
        assert binary_part(text, start_byte, end_byte - start_byte) == chunk.text
      end
    end
  end

  describe "token sizing" do
    test "chars_per_token narrows the character budget for dense text" do
      text = String.duplicate("a", 4000)

      loose = Chunker.chunk(text, size_unit: :tokens, chunk_size: 100, chunk_overlap: 0)

      dense =
        Chunker.chunk(text,
          size_unit: :tokens,
          chunk_size: 100,
          chunk_overlap: 0,
          chars_per_token: 2
        )

      loose_max = loose |> Enum.map(&byte_size(&1.text)) |> Enum.max()
      dense_max = dense |> Enum.map(&byte_size(&1.text)) |> Enum.max()

      # 100 tokens is 400 characters at the default and 200 at 2, so a
      # corpus known to be dense can be sized to stay inside the window.
      assert dense_max < loose_max
      assert dense_max <= 200
    end

    test "token_count follows chars_per_token" do
      text = String.duplicate("x", 400)

      [default] = Chunker.chunk(text, size_unit: :characters, chunk_size: 1000)

      [dense] =
        Chunker.chunk(text, size_unit: :characters, chunk_size: 1000, chars_per_token: 2)

      assert default.token_count == 100
      assert dense.token_count == 200
    end
  end

  describe "max_chunk_chars" do
    test "splits a chunk that would otherwise go out oversized" do
      # text_chunker sizes by its own rules, so an unbroken run can come out
      # longer than asked for. That is what reaches the embedder and gets a
      # 413 back.
      text = String.duplicate("a", 3000)

      unbounded = Chunker.chunk(text, size_unit: :characters, chunk_size: 5000)
      assert Enum.any?(unbounded, &(byte_size(&1.text) > 500))

      capped =
        Chunker.chunk(text, size_unit: :characters, chunk_size: 5000, max_chunk_chars: 500)

      assert Enum.all?(capped, &(byte_size(&1.text) <= 500)),
             "a chunk over the cap should be split, not emitted"
    end

    test "byte offsets still point at the source after a split" do
      text = String.duplicate("abcdefghij", 200)

      chunks =
        Chunker.chunk(text, size_unit: :characters, chunk_size: 5000, max_chunk_chars: 300)

      # Offsets feed citations, so a split must not leave them describing
      # text that isn't there.
      for chunk <- chunks do
        start = chunk.metadata["start_byte"]
        finish = chunk.metadata["end_byte"]

        assert binary_part(text, start, finish - start) == chunk.text
      end
    end

    test "never splits inside a multi-byte character" do
      text = String.duplicate("héllo wörld ", 100)

      chunks =
        Chunker.chunk(text, size_unit: :characters, chunk_size: 5000, max_chunk_chars: 50)

      for chunk <- chunks do
        assert String.valid?(chunk.text), "split produced invalid UTF-8"
        assert byte_size(chunk.text) <= 50
      end
    end
  end

  describe "option validation" do
    # Both options feed arithmetic, so an invalid one used to surface as a
    # Protocol.UndefinedError or as silently absurd output rather than as
    # the name of the option that was wrong.
    for {key, value} <- [
          {:chars_per_token, 0},
          {:chars_per_token, -1},
          {:chars_per_token, :bogus},
          {:chars_per_token, 4.0},
          {:max_chunk_chars, 0},
          {:max_chunk_chars, -5},
          {:max_chunk_chars, "500"}
        ] do
      test "rejects #{key}: #{inspect(value)}" do
        assert_raise ArgumentError, ~r/#{inspect(unquote(key))} must be a positive integer/, fn ->
          Chunker.chunk("some text to split up here. ", [{unquote(key), unquote(value)}])
        end
      end
    end

    test "rejects an overlap larger than the chunk size" do
      # The default overlap is 50, so any chunk_size below it is invalid
      # unless the caller lowers the overlap as well. text_chunker returns
      # {:error, _} for this, which used to reach Enum and surface as a
      # Protocol.UndefinedError about Tuple.
      assert_raise ArgumentError, ~r/:chunk_overlap must not be greater than :chunk_size/, fn ->
        Chunker.chunk("some text here", chunk_size: 30, size_unit: :characters)
      end

      assert_raise ArgumentError, ~r/got overlap 100 and size 10/, fn ->
        Chunker.chunk("some text here",
          chunk_size: 10,
          chunk_overlap: 100,
          size_unit: :characters
        )
      end

      # Equal is allowed, matching text_chunker's own rule.
      assert [_ | _] =
               Chunker.chunk("some text here to split",
                 chunk_size: 20,
                 chunk_overlap: 20,
                 size_unit: :characters
               )
    end

    test "the token unit is checked after conversion, and reported in tokens" do
      # With size_unit: :tokens both values scale by chars_per_token, so the
      # comparison holds either way, but the message has to quote what the
      # caller actually passed rather than the converted characters.
      assert_raise ArgumentError, ~r/got overlap 50 and size 10/, fn ->
        Chunker.chunk("some text here", chunk_size: 10, chunk_overlap: 50)
      end
    end

    test "empty input still validates its options" do
      # The empty-text clause used to return before the validators ran, so
      # the documented ArgumentError depended on the input being non-empty.
      assert_raise ArgumentError, ~r/:chars_per_token must be a positive integer/, fn ->
        Chunker.chunk("", chars_per_token: 0)
      end

      assert_raise ArgumentError, ~r/:max_chunk_chars must be a positive integer/, fn ->
        Chunker.chunk("", max_chunk_chars: -1)
      end

      assert Chunker.chunk("", max_chunk_chars: 500) == []
    end

    test "max_chunk_chars: nil is the documented default, not an error" do
      assert [_ | _] = Chunker.chunk("some text to split up here. ", max_chunk_chars: nil)
    end
  end
end
