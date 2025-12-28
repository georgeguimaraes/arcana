defmodule Arcana.ChunkerTest do
  use ExUnit.Case, async: true

  alias Arcana.Chunker

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

      chunks = Chunker.chunk(text, chunk_size: 30, size_unit: :characters)

      # Should split cleanly on \n\n
      assert Enum.any?(chunks, fn c -> c.text == "First paragraph." end)
    end

    test "handles empty text" do
      assert Chunker.chunk("") == []
    end

    test "filters out whitespace-only chunks" do
      # Text with lots of whitespace that could produce empty chunks
      text = "Content.\n\n\n\n\n\n\nMore content."

      chunks = Chunker.chunk(text, chunk_size: 20, size_unit: :characters)

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
end
