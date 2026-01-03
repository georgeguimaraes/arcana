defmodule Arcana.Graph.EntityExtractor.NER do
  @moduledoc """
  Extracts named entities from text using Bumblebee NER.

  Uses dslim/distilbert-NER to identify persons, organizations,
  locations, and miscellaneous entities. The model is lazy-loaded
  on first use to avoid startup overhead when graph features aren't needed.

  ## Usage

      # As configured extractor
      config :arcana, :graph,
        entity_extractor: :ner

      # Direct usage
      {:ok, entities} = Arcana.Graph.EntityExtractor.NER.extract(text, [])

  """

  @behaviour Arcana.Graph.EntityExtractor

  alias Arcana.Graph.NERServing

  @impl true
  @doc """
  Extracts entities from text using the NER model.

  Returns a list of entity maps with :name, :type, :span_start, :span_end, :score.
  Entities are deduplicated by name (first occurrence kept).

  ## Examples

      iex> NER.extract("Sam Altman is CEO of OpenAI.", [])
      {:ok, [
        %{name: "Sam Altman", type: "person", span_start: 0, span_end: 10, score: 0.99},
        %{name: "OpenAI", type: "organization", span_start: 22, span_end: 28, score: 0.98}
      ]}

  """
  def extract("", _opts), do: {:ok, []}

  def extract(text, _opts) when is_binary(text) do
    %{entities: raw_entities} = NERServing.run(text)

    entities =
      raw_entities
      |> Enum.map(&normalize_entity/1)
      |> deduplicate_by_name()

    {:ok, entities}
  end

  @impl true
  @doc """
  Extracts entities from multiple texts.

  ## Examples

      iex> NER.extract_batch(["Sam Altman", "Elon Musk"], [])
      {:ok, [[%{name: "Sam Altman", ...}], [%{name: "Elon Musk", ...}]]}

  """
  def extract_batch(texts, opts) when is_list(texts) do
    results = Enum.map(texts, fn text -> elem(extract(text, opts), 1) end)
    {:ok, results}
  end

  @doc """
  Maps NER labels to entity types.

  ## Label Mapping
  - PER, B-PER, I-PER → "person"
  - ORG, B-ORG, I-ORG → "organization"
  - LOC, B-LOC, I-LOC → "location"
  - MISC, B-MISC, I-MISC → "concept"
  - Other → "other"
  """
  def map_label(label) when is_binary(label) do
    label
    |> String.replace(~r/^[BI]-/, "")
    |> do_map_label()
  end

  defp do_map_label("PER"), do: "person"
  defp do_map_label("ORG"), do: "organization"
  defp do_map_label("LOC"), do: "location"
  defp do_map_label("MISC"), do: "concept"
  defp do_map_label(_), do: "other"

  defp normalize_entity(%{phrase: phrase, label: label, start: start, end: end_pos, score: score}) do
    %{
      name: String.trim(phrase),
      type: map_label(label),
      span_start: start,
      span_end: end_pos,
      score: score
    }
  end

  defp deduplicate_by_name(entities) do
    entities
    |> Enum.reduce({[], MapSet.new()}, fn entity, {acc, seen} ->
      if MapSet.member?(seen, entity.name) do
        {acc, seen}
      else
        {[entity | acc], MapSet.put(seen, entity.name)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
