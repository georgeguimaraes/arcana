# Test module implementing the Arcana.Embedder behaviour
defmodule Arcana.EmbedderTest.MockEmbedder do
  @behaviour Arcana.Embedder

  @impl Arcana.Embedder
  def embed(text, opts) do
    dims = Keyword.get(opts, :dimensions, 32)
    {:ok, List.duplicate(String.length(text) / 10, dims)}
  end

  @impl Arcana.Embedder
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, 32)
  end
end

defmodule Arcana.EmbedderTest do
  use ExUnit.Case, async: true

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
        {Arcana.Embedder.Custom, [fun: fn _text -> {:ok, List.duplicate(0.1, 32)} end]}

      assert Embedder.dimensions(embedder) == 32
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
    test "custom module implementing behaviour works with Embedder functions" do
      embedder = {Arcana.EmbedderTest.MockEmbedder, dimensions: 256}

      {:ok, embedding} = Embedder.embed(embedder, "hello world")
      assert length(embedding) == 256

      assert Embedder.dimensions(embedder) == 256
    end
  end

  describe "Local E5 model prefix support" do
    test "adds 'query: ' prefix for E5 models with intent: :query" do
      text = "what is machine learning?"

      result = Local.prepare_text(text, "intfloat/e5-small-v2", :query)

      assert result == "query: what is machine learning?"
    end

    test "adds 'passage: ' prefix for E5 models with intent: :document" do
      text = "Machine learning is a branch of AI."

      result = Local.prepare_text(text, "intfloat/e5-small-v2", :document)

      assert result == "passage: Machine learning is a branch of AI."
    end

    test "defaults to :document intent for E5 models when no intent specified" do
      text = "Some document text"

      result = Local.prepare_text(text, "intfloat/e5-base-v2", nil)

      assert result == "passage: Some document text"
    end

    test "does not add prefix for non-E5 models" do
      text = "Hello world"

      result = Local.prepare_text(text, "BAAI/bge-small-en-v1.5", :query)

      assert result == "Hello world"
    end

    test "does not add prefix for non-E5 models with document intent" do
      text = "Hello world"

      result = Local.prepare_text(text, "BAAI/bge-small-en-v1.5", :document)

      assert result == "Hello world"
    end

    test "handles all E5 model variants" do
      models = [
        "intfloat/e5-small-v2",
        "intfloat/e5-base-v2",
        "intfloat/e5-large-v2"
      ]

      for model <- models do
        assert Local.prepare_text("test", model, :query) == "query: test"
        assert Local.prepare_text("test", model, :document) == "passage: test"
      end
    end
  end
end
