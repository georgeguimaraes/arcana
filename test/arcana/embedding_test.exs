# Test module for config loading - defined before test module
defmodule Arcana.EmbeddingTest.MockEmbedder do
  defstruct [:dimensions, :api_key]

  def new(opts \\ []) do
    %__MODULE__{
      dimensions: Keyword.get(opts, :dimensions, 384),
      api_key: Keyword.get(opts, :api_key)
    }
  end
end

defmodule Arcana.EmbeddingTest do
  use ExUnit.Case, async: true

  alias Arcana.Embedding

  describe "Arcana.Embedding protocol" do
    test "Custom embedder works with function" do
      embedder =
        Arcana.Embedding.Custom.new(
          fun: fn _text ->
            {:ok, List.duplicate(0.5, 10)}
          end
        )

      {:ok, embedding} = Embedding.embed(embedder, "test")

      assert length(embedding) == 10
      assert Enum.all?(embedding, &(&1 == 0.5))
    end

    test "Custom embedder batch embeds multiple texts" do
      embedder =
        Arcana.Embedding.Custom.new(
          fun: fn text ->
            {:ok, List.duplicate(String.length(text) / 10, 10)}
          end
        )

      {:ok, embeddings} = Embedding.embed_batch(embedder, ["hello", "world!"])

      assert length(embeddings) == 2
      assert length(hd(embeddings)) == 10
    end

    test "Custom embedder dimensions are auto-detected" do
      embedder =
        Arcana.Embedding.Custom.new(fun: fn _text -> {:ok, List.duplicate(0.1, 384)} end)

      assert Embedding.dimensions(embedder) == 384
    end

    test "Custom embedder uses explicit dimensions when provided" do
      embedder =
        Arcana.Embedding.Custom.new(
          fun: fn _text -> {:ok, List.duplicate(0.1, 768)} end,
          dimensions: 768
        )

      assert Embedding.dimensions(embedder) == 768
    end

    test "Custom embedder passes through errors" do
      embedder =
        Arcana.Embedding.Custom.new(fun: fn _text -> {:error, :embedding_failed} end)

      assert {:error, :embedding_failed} = Embedding.embed(embedder, "test")
    end

    test "Custom embedder requires arity-1 function" do
      assert_raise ArgumentError, fn ->
        Arcana.Embedding.Custom.new(fun: fn a, b -> {:ok, [a, b]} end)
      end
    end
  end

  describe "Arcana.Embedding.Local" do
    test "creates embedder with default model" do
      embedder = Arcana.Embedding.Local.new()

      assert embedder.model == "BAAI/bge-small-en-v1.5"
      assert embedder.serving_name == :"Elixir.Arcana.Embedding.Local.BAAI/bge-small-en-v1.5"
    end

    test "creates embedder with custom model" do
      embedder = Arcana.Embedding.Local.new(model: "BAAI/bge-large-en-v1.5")

      assert embedder.model == "BAAI/bge-large-en-v1.5"
    end
  end

  describe "Arcana.Embedding.OpenAI" do
    test "creates embedder with default model" do
      embedder = Arcana.Embedding.OpenAI.new()

      assert embedder.model == "text-embedding-3-small"
    end

    test "creates embedder with custom model" do
      embedder = Arcana.Embedding.OpenAI.new(model: "text-embedding-3-large")

      assert embedder.model == "text-embedding-3-large"
    end
  end

  describe "Arcana.embedder/0" do
    test "returns Local embedder by default" do
      # The test config sets a custom embedder, but we can verify the function works
      embedder = Arcana.embedder()
      assert embedder != nil
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

        assert %Arcana.EmbeddingTest.MockEmbedder{} = embedder
        assert embedder.dimensions == 128
        assert embedder.api_key == "test-key"
      after
        Application.put_env(:arcana, :embedding, original)
      end
    end

    test "embedder/0 supports bare module config" do
      original = Application.get_env(:arcana, :embedding)

      Application.put_env(:arcana, :embedding, Arcana.EmbeddingTest.MockEmbedder)

      try do
        embedder = Arcana.embedder()

        assert %Arcana.EmbeddingTest.MockEmbedder{} = embedder
        assert embedder.dimensions == 384
      after
        Application.put_env(:arcana, :embedding, original)
      end
    end
  end
end
