defmodule Arcana.Grounding.AttributionTest do
  use ExUnit.Case, async: true

  alias Arcana.Grounding.Attribution

  describe "attribute/3" do
    test "full overlap scores 1.0" do
      spans = [%{text: "invented in 2010", start: 10, end: 26, score: 0.9}]
      chunks = [%{id: 1, text: "Elixir was invented in 2010 by José."}]

      [span] = Attribution.attribute(spans, chunks)

      assert [%{chunk_id: 1, score: score}] = span.sources
      assert score == 1.0
    end

    test "partial overlap scores fractionally" do
      spans = [%{text: "invented in 2010 by José", start: 0, end: 24, score: 0.8}]
      chunks = [%{id: "a", text: "It was invented in 2010."}]

      [span] = Attribution.attribute(spans, chunks)

      [%{chunk_id: "a", score: score}] = span.sources
      assert score > 0.5
      assert score < 1.0
    end

    test "no overlap returns empty sources" do
      spans = [%{text: "quantum computing rocks", start: 0, end: 23, score: 0.9}]
      chunks = [%{id: 1, text: "Elixir is a programming language."}]

      [span] = Attribution.attribute(spans, chunks)

      assert span.sources == []
    end

    test "empty spans returns empty list" do
      assert Attribution.attribute([], [%{id: 1, text: "some chunk"}]) == []
    end

    test "empty chunks adds empty sources to all spans" do
      spans = [%{text: "hello world", start: 0, end: 11, score: 0.5}]

      [span] = Attribution.attribute(spans, [])

      assert span.sources == []
    end

    test "chunks without id field get nil chunk_id" do
      spans = [%{text: "hello world", start: 0, end: 11, score: 0.5}]
      chunks = [%{text: "hello world is a common greeting"}]

      [span] = Attribution.attribute(spans, chunks)

      assert [%{chunk_id: nil, score: _}] = span.sources
    end

    test "single-word span" do
      spans = [%{text: "Elixir", start: 0, end: 6, score: 0.5}]

      chunks = [
        %{id: 1, text: "Elixir is great."},
        %{id: 2, text: "Python is nice."}
      ]

      [span] = Attribution.attribute(spans, chunks)

      assert [%{chunk_id: 1, score: 1.0}] = span.sources
    end

    test "multiple chunks scored and sorted by score desc" do
      spans = [%{text: "Elixir runs on BEAM", start: 0, end: 19, score: 0.7}]

      chunks = [
        %{id: 1, text: "Elixir is a language."},
        %{id: 2, text: "Elixir runs on the BEAM virtual machine."},
        %{id: 3, text: "Unrelated content here."}
      ]

      [span] = Attribution.attribute(spans, chunks)

      assert length(span.sources) == 2
      assert hd(span.sources).chunk_id == 2
      assert hd(span.sources).score > Enum.at(span.sources, 1).score
    end

    test "respects min_score option" do
      spans = [%{text: "Elixir runs on BEAM VM", start: 0, end: 22, score: 0.7}]
      chunks = [%{id: 1, text: "Elixir is great for concurrency."}]

      [span] = Attribution.attribute(spans, chunks, min_score: 0.5)

      assert span.sources == []
    end

    test "case-insensitive matching" do
      spans = [%{text: "ELIXIR is Great", start: 0, end: 15, score: 0.5}]
      chunks = [%{id: 1, text: "elixir is great for web development"}]

      [span] = Attribution.attribute(spans, chunks)

      assert [%{chunk_id: 1, score: 1.0}] = span.sources
    end

    test "multiple spans attributed independently" do
      spans = [
        %{text: "invented in 2010", start: 0, end: 16, score: 0.9},
        %{text: "runs on JVM", start: 20, end: 31, score: 0.8}
      ]

      chunks = [
        %{id: 1, text: "Elixir was created in 2011, not 2010."},
        %{id: 2, text: "Elixir runs on the BEAM, not JVM."}
      ]

      [span1, span2] = Attribution.attribute(spans, chunks)

      span1_ids = Enum.map(span1.sources, & &1.chunk_id)
      span2_ids = Enum.map(span2.sources, & &1.chunk_id)

      assert 1 in span1_ids
      assert 2 in span2_ids
    end
  end
end
