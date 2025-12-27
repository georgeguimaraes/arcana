# Test module implementing the Arcana.Embedding behaviour
defmodule Arcana.EmbeddingTest.MockEmbedder do
  @behaviour Arcana.Embedding

  @impl Arcana.Embedding
  def embed(text, opts) do
    dims = Keyword.get(opts, :dimensions, 384)
    {:ok, List.duplicate(String.length(text) / 10, dims)}
  end

  @impl Arcana.Embedding
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, 384)
  end
end

defmodule Arcana.EmbeddingTest do
  use ExUnit.Case, async: true

  alias Arcana.Embedding
  alias Arcana.Embedding.Local
  alias Arcana.Embedding.OpenAI

  describe "Arcana.Embedding behaviour with Custom (function wrapper)" do
    test "Custom embedder works with function" do
      embedder = {Arcana.Embedding.Custom, [fun: fn _text -> {:ok, List.duplicate(0.5, 10)} end]}

      {:ok, embedding} = Embedding.embed(embedder, "test")

      assert length(embedding) == 10
      assert Enum.all?(embedding, &(&1 == 0.5))
    end

    test "Custom embedder batch embeds multiple texts" do
      embedder =
        {Arcana.Embedding.Custom,
         [
           fun: fn text ->
             {:ok, List.duplicate(String.length(text) / 10, 10)}
           end
         ]}

      {:ok, embeddings} = Embedding.embed_batch(embedder, ["hello", "world!"])

      assert length(embeddings) == 2
      assert length(hd(embeddings)) == 10
    end

    test "Custom embedder dimensions are auto-detected" do
      embedder =
        {Arcana.Embedding.Custom, [fun: fn _text -> {:ok, List.duplicate(0.1, 384)} end]}

      assert Embedding.dimensions(embedder) == 384
    end

    test "Custom embedder uses explicit dimensions when provided" do
      embedder =
        {Arcana.Embedding.Custom,
         [fun: fn _text -> {:ok, List.duplicate(0.1, 768)} end, dimensions: 768]}

      assert Embedding.dimensions(embedder) == 768
    end

    test "Custom embedder passes through errors" do
      embedder = {Arcana.Embedding.Custom, [fun: fn _text -> {:error, :embedding_failed} end]}

      assert {:error, :embedding_failed} = Embedding.embed(embedder, "test")
    end
  end

  describe "Local" do
    test "returns correct dimensions for known models" do
      assert Local.dimensions([]) == 384
      assert Local.dimensions(model: "BAAI/bge-small-en-v1.5") == 384
      assert Local.dimensions(model: "BAAI/bge-base-en-v1.5") == 768
      assert Local.dimensions(model: "BAAI/bge-large-en-v1.5") == 1024
    end
  end

  describe "OpenAI" do
    test "returns correct dimensions for known models" do
      assert OpenAI.dimensions([]) == 1536
      assert OpenAI.dimensions(model: "text-embedding-3-small") == 1536
      assert OpenAI.dimensions(model: "text-embedding-3-large") == 3072
      assert OpenAI.dimensions(model: "text-embedding-ada-002") == 1536
    end
  end

  describe "Arcana.embedder/0" do
    test "returns {module, opts} tuple" do
      embedder = Arcana.embedder()
      assert {module, opts} = embedder
      assert is_atom(module)
      assert is_list(opts)
    end
  end

  describe "custom module config" do
    test "embedder/0 supports {module, opts} config" do
      original = Application.get_env(:arcana, :embedding)

      Application.put_env(
        :arcana,
        :embedding,
        {Arcana.EmbeddingTest.MockEmbedder, dimensions: 128, api_key: "test-key"}
      )

      try do
        embedder = Arcana.embedder()

        assert {Arcana.EmbeddingTest.MockEmbedder, opts} = embedder
        assert Keyword.get(opts, :dimensions) == 128
        assert Keyword.get(opts, :api_key) == "test-key"
      after
        Application.put_env(:arcana, :embedding, original)
      end
    end

    test "embedder/0 supports bare module config" do
      original = Application.get_env(:arcana, :embedding)

      Application.put_env(:arcana, :embedding, Arcana.EmbeddingTest.MockEmbedder)

      try do
        embedder = Arcana.embedder()

        assert {Arcana.EmbeddingTest.MockEmbedder, []} = embedder
      after
        Application.put_env(:arcana, :embedding, original)
      end
    end

    test "custom module implementing behaviour works with Embedding functions" do
      embedder = {Arcana.EmbeddingTest.MockEmbedder, dimensions: 256}

      {:ok, embedding} = Embedding.embed(embedder, "hello world")
      assert length(embedding) == 256

      assert Embedding.dimensions(embedder) == 256
    end
  end
end
