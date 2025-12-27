defmodule Arcana.VectorStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Arcana.VectorStore.Memory

  setup do
    # Start a fresh Memory server for each test
    {:ok, pid} = Memory.start_link(name: nil)
    %{pid: pid}
  end

  describe "store/5" do
    test "stores a vector with id and metadata", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      metadata = %{text: "hello world", chunk_index: 0}

      assert :ok = Memory.store(pid, "default", "chunk-1", embedding, metadata)
    end

    test "stores multiple vectors in same collection", %{pid: pid} do
      embedding1 = List.duplicate(0.5, 384)
      embedding2 = List.duplicate(0.3, 384)

      assert :ok = Memory.store(pid, "default", "chunk-1", embedding1, %{text: "hello"})
      assert :ok = Memory.store(pid, "default", "chunk-2", embedding2, %{text: "world"})
    end

    test "stores vectors in different collections", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)

      assert :ok = Memory.store(pid, "docs", "chunk-1", embedding, %{text: "doc"})
      assert :ok = Memory.store(pid, "products", "chunk-2", embedding, %{text: "product"})
    end
  end

  describe "search/4" do
    test "returns empty list for empty collection", %{pid: pid} do
      query = List.duplicate(0.5, 384)

      assert [] = Memory.search(pid, "default", query, limit: 10)
    end

    test "finds stored vectors", %{pid: pid} do
      # Store some vectors
      embedding1 = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      embedding2 = normalize([0.0, 1.0, 0.0] ++ List.duplicate(0.0, 381))
      embedding3 = normalize([0.9, 0.1, 0.0] ++ List.duplicate(0.0, 381))

      :ok = Memory.store(pid, "default", "chunk-1", embedding1, %{text: "first"})
      :ok = Memory.store(pid, "default", "chunk-2", embedding2, %{text: "second"})
      :ok = Memory.store(pid, "default", "chunk-3", embedding3, %{text: "third"})

      # Query similar to embedding1
      query = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      results = Memory.search(pid, "default", query, limit: 2)

      assert length(results) == 2

      # Should find chunk-1 and chunk-3 as most similar
      ids = Enum.map(results, & &1.id)
      assert "chunk-1" in ids
      assert "chunk-3" in ids
    end

    test "respects limit option", %{pid: pid} do
      for i <- 1..5 do
        embedding = normalize([i / 10.0] ++ List.duplicate(0.0, 383))
        :ok = Memory.store(pid, "default", "chunk-#{i}", embedding, %{text: "text #{i}"})
      end

      query = normalize([0.5] ++ List.duplicate(0.0, 383))
      results = Memory.search(pid, "default", query, limit: 3)

      assert length(results) == 3
    end

    test "returns results with score", %{pid: pid} do
      embedding = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      :ok = Memory.store(pid, "default", "chunk-1", embedding, %{text: "hello"})

      query = normalize([1.0, 0.0, 0.0] ++ List.duplicate(0.0, 381))
      [result] = Memory.search(pid, "default", query, limit: 1)

      assert result.id == "chunk-1"
      assert result.metadata == %{text: "hello"}
      # Score should be close to 1.0 for identical vectors
      assert result.score > 0.99
    end

    test "searches specific collection only", %{pid: pid} do
      embedding = normalize([1.0] ++ List.duplicate(0.0, 383))

      :ok = Memory.store(pid, "docs", "doc-1", embedding, %{text: "doc"})
      :ok = Memory.store(pid, "products", "prod-1", embedding, %{text: "product"})

      query = embedding
      doc_results = Memory.search(pid, "docs", query, limit: 10)
      prod_results = Memory.search(pid, "products", query, limit: 10)

      assert length(doc_results) == 1
      assert hd(doc_results).id == "doc-1"

      assert length(prod_results) == 1
      assert hd(prod_results).id == "prod-1"
    end
  end

  describe "delete/3" do
    test "removes vector from collection", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      :ok = Memory.store(pid, "default", "chunk-1", embedding, %{text: "hello"})

      # Verify it's there
      results = Memory.search(pid, "default", embedding, limit: 10)
      assert length(results) == 1

      # Delete it
      assert :ok = Memory.delete(pid, "default", "chunk-1")

      # Verify it's gone
      results = Memory.search(pid, "default", embedding, limit: 10)
      assert length(results) == 0
    end

    test "returns error for non-existent id", %{pid: pid} do
      assert {:error, :not_found} = Memory.delete(pid, "default", "non-existent")
    end
  end

  describe "clear/2" do
    test "removes all vectors from collection", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      :ok = Memory.store(pid, "default", "chunk-1", embedding, %{text: "hello"})
      :ok = Memory.store(pid, "default", "chunk-2", embedding, %{text: "world"})

      assert :ok = Memory.clear(pid, "default")

      results = Memory.search(pid, "default", embedding, limit: 10)
      assert results == []
    end

    test "only clears specified collection", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      :ok = Memory.store(pid, "docs", "doc-1", embedding, %{text: "doc"})
      :ok = Memory.store(pid, "products", "prod-1", embedding, %{text: "product"})

      assert :ok = Memory.clear(pid, "docs")

      # Docs should be empty
      assert [] = Memory.search(pid, "docs", embedding, limit: 10)

      # Products should still have data
      results = Memory.search(pid, "products", embedding, limit: 10)
      assert length(results) == 1
    end
  end

  # Helper to normalize a vector to unit length (for cosine similarity)
  defp normalize(vector) do
    magnitude = :math.sqrt(Enum.reduce(vector, 0.0, fn x, sum -> sum + x * x end))

    if magnitude > 0 do
      Enum.map(vector, &(&1 / magnitude))
    else
      vector
    end
  end
end
