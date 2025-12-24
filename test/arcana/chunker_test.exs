defmodule Arcana.ChunkerTest do
  use ExUnit.Case, async: true

  alias Arcana.Chunker

  describe "chunk/2" do
    test "splits text into chunks of specified size" do
      # ~2500 chars
      text = String.duplicate("word ", 500)

      chunks = Chunker.chunk(text, chunk_size: 1024)

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

      chunks = Chunker.chunk(text, chunk_size: 500)

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

      chunks = Chunker.chunk(text, chunk_size: 30)

      # Should split cleanly on \n\n
      assert Enum.any?(chunks, fn c -> c.text == "First paragraph." end)
    end

    test "handles empty text" do
      assert Chunker.chunk("") == []
    end
  end
end
