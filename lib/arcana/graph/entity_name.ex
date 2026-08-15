defmodule Arcana.Graph.EntityName do
  @moduledoc """
  Normalizes entity names into deduplication keys.

  LLM extractors return cosmetic variants of the same real-world entity
  across chunks ("Two_Year_Limited_Warranty" vs "two year limited
  warranty"). GraphBuilder and the graph stores compute their dedup and
  upsert keys through this module so they agree on which names refer to
  the same entity. Display names keep their first-seen original form.
  """

  @doc """
  Returns the canonical dedup key for an entity name.

  Case-folds, converts underscores and hyphens to spaces, collapses
  whitespace, and trims:

      iex> Arcana.Graph.EntityName.normalize("Two_Year_Limited_Warranty")
      "two year limited warranty"

  """
  def normalize(nil), do: nil

  def normalize(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[_\-]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
