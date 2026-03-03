defmodule Arcana.Grounding.Attribution do
  @moduledoc """
  Attributes grounding spans to source chunks using word overlap scoring.

  For each span (hallucinated or faithful), computes what fraction of its words
  appear in each chunk. This is directional: a span "invented in 2010" gets 1.0
  against a chunk containing those exact words, regardless of chunk length.

      score = |words(span) ∩ words(chunk)| / |words(span)|
  """

  @default_min_score 0.1

  @doc """
  Adds `:sources` to each span based on word overlap with chunks.

  Returns spans with a `:sources` field: a list of `%{chunk_id: term(), score: float()}`
  sorted by score descending, filtered by `min_score` (default #{@default_min_score}).

  ## Options

  - `:min_score` - Minimum overlap score to include a chunk (default: #{@default_min_score})
  """
  @spec attribute([map()], [map()], keyword()) :: [map()]
  def attribute(spans, chunks, opts \\ [])
  def attribute([], _chunks, _opts), do: []
  def attribute(spans, [], _opts), do: Enum.map(spans, &Map.put(&1, :sources, []))

  def attribute(spans, chunks, opts) do
    min_score = Keyword.get(opts, :min_score, @default_min_score)

    chunk_word_sets =
      Enum.map(chunks, fn chunk ->
        {chunk_id(chunk), word_set(chunk.text)}
      end)

    Enum.map(spans, fn span ->
      sources = score_span(span, chunk_word_sets, min_score)
      Map.put(span, :sources, sources)
    end)
  end

  defp score_span(span, chunk_word_sets, min_score) do
    span_words = word_set(span.text)

    if MapSet.size(span_words) == 0 do
      []
    else
      chunk_word_sets
      |> Enum.map(fn {id, chunk_words} ->
        overlap = MapSet.intersection(span_words, chunk_words) |> MapSet.size()
        %{chunk_id: id, score: overlap / MapSet.size(span_words)}
      end)
      |> Enum.filter(&(&1.score >= min_score))
      |> Enum.sort_by(& &1.score, :desc)
    end
  end

  defp word_set(text) do
    Regex.scan(~r/\w+/u, text)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp chunk_id(%{id: id}), do: id
  defp chunk_id(_), do: nil
end
