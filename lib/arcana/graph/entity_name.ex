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

    * Case folding. The two engines disagree on an open-ended set of
      codepoints, and the set depends on the database host's libc, not on
      anything this library controls. Sweeping U+0001..U+2FFFD against
      PostgreSQL 16.15 on glibc found 56: U+0130, U+1C89, U+A7CB, U+A7CC,
      U+A7CE, U+A7D2, U+A7D4, U+A7DA, U+A7DC, U+10D50..U+10D65 (Garay) and
      U+16EA0..U+16EB8. All but the first are glibc lagging Unicode, so a
      newer or older host shifts the list; U+0130 (`İ`) is the one that
      diverges by Unicode's own SpecialCasing rules, and so behaves the
      same everywhere: `String.downcase/1` decomposes it into `i` plus a
      combining dot while Postgres' `lower()` folds it to a bare `i`, which
      makes `"İstanbul"` and `"istanbul"` one entity in the Ecto store and
      two in the Memory store.

      Do not treat any of these as a closed list. The Ecto store keys its
      returned id map on the raw name for exactly this reason, so a
      spelling pair the two engines disagree about still reaches its own
      row whatever the host libc thinks.

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
