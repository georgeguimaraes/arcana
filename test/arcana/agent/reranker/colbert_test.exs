defmodule Arcana.Agent.Reranker.ColBERTTest do
  @moduledoc """
  Tests for ColBERT reranker.

  Run with: mix test --include colbert
  """
  use Arcana.DataCase, async: false

  alias Arcana.Agent.Reranker.ColBERT

  # ColBERT tests require Stephen which loads a model (slow)
  @moduletag :colbert

  describe "rerank/3" do
    setup do
      # Skip if Stephen is not available
      unless Code.ensure_loaded?(Stephen) do
        {:skip, "Stephen not available"}
      else
        # Load encoder once for all tests
        {:ok, encoder} = Stephen.load_encoder()
        {:ok, encoder: encoder}
      end
    end

    test "returns empty list for empty chunks", %{encoder: encoder} do
      assert {:ok, []} = ColBERT.rerank("query", [], encoder: encoder)
    end

    test "reranks chunks by semantic relevance", %{encoder: encoder} do
      chunks = [
        %{id: "1", text: "The weather is sunny today.", document_id: "doc1"},
        %{id: "2", text: "Elixir is a functional programming language.", document_id: "doc2"},
        %{id: "3", text: "Python is great for machine learning.", document_id: "doc3"}
      ]

      {:ok, results} = ColBERT.rerank("functional programming language", chunks, encoder: encoder)

      # Elixir chunk should rank highest for this query
      assert length(results) > 0
      first = hd(results)
      assert first.text =~ "Elixir" or first.text =~ "functional"
      assert Map.has_key?(first, :rerank_score)
    end

    test "respects top_k option", %{encoder: encoder} do
      chunks = [
        %{id: "1", text: "First document about programming.", document_id: "doc1"},
        %{id: "2", text: "Second document about coding.", document_id: "doc2"},
        %{id: "3", text: "Third document about software.", document_id: "doc3"}
      ]

      {:ok, results} = ColBERT.rerank("programming", chunks, encoder: encoder, top_k: 2)

      assert length(results) == 2
    end

    test "respects threshold option", %{encoder: encoder} do
      chunks = [
        %{id: "1", text: "Elixir is a functional programming language.", document_id: "doc1"},
        %{id: "2", text: "The sky is blue and grass is green.", document_id: "doc2"}
      ]

      # Use a high threshold to filter out less relevant results
      {:ok, results} =
        ColBERT.rerank("Elixir programming", chunks, encoder: encoder, threshold: 10.0)

      # At least the Elixir chunk should score above 10 for this exact query
      assert Enum.all?(results, fn r -> r.rerank_score >= 10.0 end)
    end

    test "adds rerank_score to each result", %{encoder: encoder} do
      chunks = [
        %{id: "1", text: "Test document content.", document_id: "doc1", extra_field: "preserved"}
      ]

      {:ok, [result]} = ColBERT.rerank("test", chunks, encoder: encoder)

      assert is_number(result.rerank_score)
      assert result.rerank_score > 0
      # Original fields are preserved
      assert result.id == "1"
      assert result.extra_field == "preserved"
    end
  end

  describe "rerank/3 without Stephen" do
    test "raises helpful error when Stephen is not loaded" do
      # This test runs without the :colbert tag to verify error handling
      # We can't actually test this when Stephen IS loaded, so we skip
      # if Stephen is available
      if Code.ensure_loaded?(Stephen) do
        :ok
      else
        chunks = [%{id: "1", text: "test", document_id: "doc1"}]

        assert_raise RuntimeError, ~r/Stephen is required/, fn ->
          ColBERT.rerank("query", chunks, [])
        end
      end
    end
  end
end
