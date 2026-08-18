defmodule Arcana.SearchResultTest do
  use ExUnit.Case, async: true

  doctest Arcana.SearchResult

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

  describe "to_map/1" do
    test "returns every documented field, including the nils" do
      result = %Arcana.SearchResult{
        id: "chunk-1",
        text: "hello",
        document_id: "doc-1",
        chunk_index: 3,
        score: 0.75,
        metadata: %{"page_start" => 4}
      }

      map = Arcana.SearchResult.to_map(result)

      assert map == %{
               id: "chunk-1",
               text: "hello",
               document_id: "doc-1",
               chunk_index: 3,
               score: 0.75,
               vector_score: nil,
               keyword_score: nil,
               rerank_score: nil,
               metadata: %{"page_start" => 4}
             }
    end

    test "is a plain map, so it encodes" do
      result = %Arcana.SearchResult{id: "a", text: "t", score: 1.0}

      # The struct itself does not encode, which is the deliberate part.
      assert_raise Protocol.UndefinedError, fn -> JSON.encode!(result) end

      # to_map/1 is the supported seam.
      assert is_binary(JSON.encode!(Arcana.SearchResult.to_map(result)))
    end

    test "does not leak a field the struct gains later" do
      # The contract is one-directional: to_map/1 must not expose keys beyond
      # this set. Adding a field to the struct does not fail this test, and
      # should not - to_map/1 lists its keys, so a new field stays private
      # until someone adds it here on purpose. What this catches is that
      # edit: widening to_map/1 without widening the documented set.
      documented =
        MapSet.new([
          :id,
          :text,
          :document_id,
          :chunk_index,
          :score,
          :vector_score,
          :keyword_score,
          :rerank_score,
          :metadata
        ])

      actual =
        %Arcana.SearchResult{} |> Arcana.SearchResult.to_map() |> Map.keys() |> MapSet.new()

      assert actual == documented
    end
  end
end
