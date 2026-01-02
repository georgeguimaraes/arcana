defmodule Arcana.Embeddings.ServingTest do
  use ExUnit.Case, async: true

  alias Arcana.Embeddings.Serving

  describe "embed/1" do
    test "returns 32-dimensional vector for text" do
      embedding = Serving.embed("Hello world")

      assert is_list(embedding)
      assert length(embedding) == 32
      assert Enum.all?(embedding, &is_float/1)
    end

    test "returns different embeddings for different texts" do
      embedding1 = Serving.embed("Hello world")
      embedding2 = Serving.embed("Goodbye moon")

      assert embedding1 != embedding2
    end

    test "returns similar embeddings for similar texts" do
      embedding1 = Serving.embed("The cat sat on the mat")
      embedding2 = Serving.embed("The cat was sitting on the mat")

      similarity = cosine_similarity(embedding1, embedding2)
      assert similarity > 0.8
    end
  end

  describe "embed_batch/1" do
    test "embeds multiple texts at once" do
      texts = ["Hello", "World", "Test"]

      embeddings = Serving.embed_batch(texts)

      assert length(embeddings) == 3
      assert Enum.all?(embeddings, fn e -> length(e) == 32 end)
    end
  end

  defp cosine_similarity(a, b) do
    dot = Enum.zip(a, b) |> Enum.map(fn {x, y} -> x * y end) |> Enum.sum()
    norm_a = :math.sqrt(Enum.map(a, fn x -> x * x end) |> Enum.sum())
    norm_b = :math.sqrt(Enum.map(b, fn x -> x * x end) |> Enum.sum())
    dot / (norm_a * norm_b)
  end
end
