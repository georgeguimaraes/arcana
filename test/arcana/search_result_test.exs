defmodule Arcana.SearchResultTest do
  use ExUnit.Case, async: true

  alias Arcana.SearchResult

  describe "from_store_result/1" do
    test "extracts well-known keys and keeps the rest as string-keyed metadata" do
      result =
        SearchResult.from_store_result(%{
          id: "chunk-1",
          score: 0.87,
          metadata: %{
            :text => "some chunk text",
            :chunk_index => 2,
            :document_id => "doc-1",
            :vector_score => 0.9,
            :keyword_score => 0.4,
            "team" => "zoology",
            :custom => 1
          }
        })

      assert %SearchResult{} = result
      assert result.id == "chunk-1"
      assert result.text == "some chunk text"
      assert result.chunk_index == 2
      assert result.document_id == "doc-1"
      assert result.score == 0.87
      assert result.vector_score == 0.9
      assert result.keyword_score == 0.4
      assert result.metadata == %{"team" => "zoology", "custom" => 1}
    end

    test "accepts well-known keys as strings (JSONB round-trips, custom backends)" do
      result =
        SearchResult.from_store_result(%{
          id: "chunk-3",
          score: 0.5,
          metadata: %{"text" => "string keyed", "document_id" => "doc-9", "team" => "zoology"}
        })

      assert result.text == "string keyed"
      assert result.document_id == "doc-9"
      assert result.metadata == %{"team" => "zoology"}
    end

    test "tolerates nil metadata and missing keys" do
      result = SearchResult.from_store_result(%{id: "chunk-2", score: 0.1, metadata: nil})

      assert result.text == ""
      assert is_nil(result.document_id)
      assert is_nil(result.vector_score)
      assert result.metadata == %{}
    end
  end

  describe "Access" do
    test "bracket reads work like the previous plain maps" do
      result = %SearchResult{id: "x", text: "hello", score: 1.0}

      assert result[:text] == "hello"
      assert result[:score] == 1.0
      assert is_nil(result[:document_id])
      assert is_nil(result[:not_a_field])
    end

    test "get_and_update replaces existing fields" do
      result = %SearchResult{id: "x", text: "hello", score: 1.0}

      {old, updated} = Access.get_and_update(result, :score, fn s -> {s, s * 2} end)
      assert old == 1.0
      assert updated.score == 2.0
    end

    test "updates on unknown keys raise a clear error" do
      result = %SearchResult{id: "x", text: "hello", score: 1.0}

      assert_raise ArgumentError, ~r/only supports Access updates/, fn ->
        Access.get_and_update(result, :not_a_field, fn v -> {v, 1} end)
      end

      assert_raise ArgumentError, ~r/only supports Access updates/, fn ->
        Access.pop(result, "text")
      end

      assert_raise ArgumentError, ~r/only supports Access updates/, fn ->
        Access.get_and_update(result, :__struct__, fn v -> {v, SomethingElse} end)
      end
    end

    test "popping metadata resets it to an empty map" do
      result = %SearchResult{id: "x", text: "t", score: 1.0, metadata: %{"a" => 1}}

      assert {%{"a" => 1}, %SearchResult{metadata: %{}}} = Access.pop(result, :metadata)
    end
  end
end
