defmodule Arcana.Graph.EntityName do
  @moduledoc """
  Normalizes entity names into deduplication keys.

  LLM extractors return cosmetic variants of the same real-world entity
  across chunks ("Two_Year_Limited_Warranty" vs "two year limited
  warranty"). GraphBuilder and the graph stores compute their dedup and
  upsert keys through this module so they agree on which names refer to
  the same entity. Display names keep their first-seen original form.

  ## Backend differences

  The Ecto store computes the same key in SQL (see
  `Arcana.Graph.GraphStore.Ecto`) because it has to compare a stored name
  against an incoming one inside a query. Whitespace folds identically on
  both sides: each collapses the full Unicode White_Space set, which is
  wider than Postgres' `\\s` (it doesn't match NBSP) and wider than
  Elixir's (ASCII only).

  Two differences remain, and are deliberate:

    * Case folding of U+0130 (`İ`). `String.downcase/1` decomposes it into
      `i` plus a combining dot; Postgres' `lower()` folds it to a bare
      `i`. So `"İstanbul"` and `"istanbul"` are one entity in the Ecto
      store and two in the Memory store.

    * Neither backend applies canonical normalization, so NFC `"Café"` and
      NFD `"Café"` are different entities in both.

  """

  @doc """
  Returns the canonical dedup key for an entity name.

  Case-folds, converts underscores and hyphens to spaces, collapses
  whitespace, and trims:

      iex> Arcana.Graph.EntityName.normalize("Two_Year_Limited_Warranty")
      "two year limited warranty"

  """
  # The Unicode White_Space set, spelled out. Elixir's `\s` is ASCII-only
  # even under /u, so it leaves the NBSP that arrives with every
  # HTML/PDF-derived name — and every space separator Postgres' `\s` does
  # fold — sitting inside the key.
  @whitespace ~r/[\x{0009}-\x{000D}\x{0020}\x{0085}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]+/u

  def normalize(nil), do: nil

  def normalize(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[_\-]+/, " ")
    |> String.replace(@whitespace, " ")
    |> String.trim()
  end
end
