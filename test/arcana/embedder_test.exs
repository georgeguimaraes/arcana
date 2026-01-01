# Test module implementing the Arcana.Embedder behaviour
defmodule Arcana.EmbedderTest.MockEmbedder do
  @behaviour Arcana.Embedder

  @impl Arcana.Embedder
  def embed(text, opts) do
    dims = Keyword.get(opts, :dimensions, 384)
    {:ok, List.duplicate(String.length(text) / 10, dims)}
  end

  @impl Arcana.Embedder
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, 384)
  end
end

defmodule Arcana.EmbedderTest do
  # Cannot be async because tests modify global application config
  use ExUnit.Case, async: false

  alias Arcana.Embedder
  alias Arcana.Embedder.Local
  alias Arcana.Embedder.OpenAI

  describe "Arcana.Embedder behaviour with Custom (function wrapper)" do
    test "Custom embedder works with function" do
      embedder = {Arcana.Embedder.Custom, [fun: fn _text -> {:ok, List.duplicate(0.5, 10)} end]}

      {:ok, embedding} = Embedder.embed(embedder, "test")

      assert length(embedding) == 10
      assert Enum.all?(embedding, &(&1 == 0.5))
    end

    test "Custom embedder batch embeds multiple texts" do
      embedder =
        {Arcana.Embedder.Custom,
         [
           fun: fn text ->
             {:ok, List.duplicate(String.length(text) / 10, 10)}
           end
         ]}

      {:ok, embeddings} = Embedder.embed_batch(embedder, ["hello", "world!"])

      assert length(embeddings) == 2
      assert length(hd(embeddings)) == 10
    end

    test "Custom embedder dimensions are auto-detected" do
      embedder =
        {Arcana.Embedder.Custom, [fun: fn _text -> {:ok, List.duplicate(0.1, 384)} end]}

      assert Embedder.dimensions(embedder) == 384
    end

    test "Custom embedder uses explicit dimensions when provided" do
      embedder =
        {Arcana.Embedder.Custom,
         [fun: fn _text -> {:ok, List.duplicate(0.1, 768)} end, dimensions: 768]}

      assert Embedder.dimensions(embedder) == 768
    end

    test "Custom embedder passes through errors" do
      embedder = {Arcana.Embedder.Custom, [fun: fn _text -> {:error, :embedding_failed} end]}

      assert {:error, :embedding_failed} = Embedder.embed(embedder, "test")
    end
  end

  describe "Local" do
    test "returns correct dimensions for BGE models" do
      assert Local.dimensions([]) == 384
      assert Local.dimensions(model: "BAAI/bge-small-en-v1.5") == 384
      assert Local.dimensions(model: "BAAI/bge-base-en-v1.5") == 768
      assert Local.dimensions(model: "BAAI/bge-large-en-v1.5") == 1024
    end

    test "returns correct dimensions for E5 models" do
      assert Local.dimensions(model: "intfloat/e5-small-v2") == 384
      assert Local.dimensions(model: "intfloat/e5-base-v2") == 768
      assert Local.dimensions(model: "intfloat/e5-large-v2") == 1024
    end

    test "returns correct dimensions for GTE models" do
      assert Local.dimensions(model: "thenlper/gte-small") == 384
      assert Local.dimensions(model: "thenlper/gte-base") == 768
      assert Local.dimensions(model: "thenlper/gte-large") == 1024
    end

    test "returns correct dimensions for Sentence Transformers models" do
      assert Local.dimensions(model: "sentence-transformers/all-MiniLM-L6-v2") == 384
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
      original = Application.get_env(:arcana, :embedder)

      Application.put_env(
        :arcana,
        :embedder,
        {Arcana.EmbedderTest.MockEmbedder, dimensions: 128, api_key: "test-key"}
      )

      try do
        embedder = Arcana.embedder()

        assert {Arcana.EmbedderTest.MockEmbedder, opts} = embedder
        assert Keyword.get(opts, :dimensions) == 128
        assert Keyword.get(opts, :api_key) == "test-key"
      after
        Application.put_env(:arcana, :embedder, original)
      end
    end

    test "embedder/0 supports bare module config" do
      original = Application.get_env(:arcana, :embedder)

      Application.put_env(:arcana, :embedder, Arcana.EmbedderTest.MockEmbedder)

      try do
        embedder = Arcana.embedder()

        assert {Arcana.EmbedderTest.MockEmbedder, []} = embedder
      after
        Application.put_env(:arcana, :embedder, original)
      end
    end

    test "custom module implementing behaviour works with Embedder functions" do
      embedder = {Arcana.EmbedderTest.MockEmbedder, dimensions: 256}

      {:ok, embedding} = Embedder.embed(embedder, "hello world")
      assert length(embedding) == 256

      assert Embedder.dimensions(embedder) == 256
    end
  end
end
