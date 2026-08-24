defmodule Arcana.SearchRrfWeightsTest do
  @moduledoc """
  Reciprocal rank fusion and the weight options.

  `rrf_combine/5` used to take no weights at all, so every backend fused through
  it discarded `:vector_weight` and `:keyword_weight` silently - the same
  documented-but-unimplemented shape as `:hnsw_ef_search` before it was wired up.

  Canonical RRF (Cormack et al. 2009) is unweighted, and equal weights reproduce
  it exactly: scaling both sides by the same factor cannot reorder anything. So
  the default is still the algorithm as published, and the weights only bite when
  they differ.
  """
  use ExUnit.Case, async: true

  alias Arcana.Search

  # Disjoint lists so each item's rank comes from exactly one side, which makes
  # the weight arithmetic legible: with k = 60, rank 1 scores w/61.
  @vector_only [%{id: "v1"}, %{id: "v2"}]
  @keyword_only [%{id: "k1"}, %{id: "k2"}]

  defp ids(results), do: Enum.map(results, & &1.id)

  describe "weights" do
    test "equal weights rank identically to unweighted RRF" do
      unweighted = Search.rrf_combine(@vector_only, @keyword_only, 4, 60)
      equal = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {1.0, 1.0})
      halved = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.5, 0.5})

      assert ids(unweighted) == ids(equal)

      assert ids(unweighted) == ids(halved),
             "a uniform scale factor cannot change the ordering"
    end

    test "favouring the vector side puts its results first" do
      results = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.9, 0.1})

      assert ids(results) == ["v1", "v2", "k1", "k2"]
    end

    test "favouring the keyword side reverses that" do
      results = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.1, 0.9})

      assert ids(results) == ["k1", "k2", "v1", "v2"]
    end

    test "a zero weight removes a side's contribution without dropping its items" do
      results = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {1.0, 0.0})

      assert ids(results) == ["v1", "v2", "k1", "k2"]

      for r <- results, r.id in ["k1", "k2"] do
        assert r.score == 0.0, "a zero-weighted side should contribute nothing"
      end
    end

    test "an item in both lists still accumulates from each side" do
      shared = %{id: "both"}

      results =
        Search.rrf_combine([shared | @vector_only], [shared | @keyword_only], 5, 60, {1.0, 1.0})

      assert hd(results).id == "both",
             "appearing in both lists is what RRF rewards"

      assert hd(results).score == 1.0 / 61 + 1.0 / 61
    end

    test "the arity-4 form still works for callers that do not weight" do
      # The graph fusion path calls it this way, so the default has to hold.
      assert ids(Search.rrf_combine(@vector_only, @keyword_only, 4)) ==
               ids(Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {1.0, 1.0}))
    end

    test "limit still truncates after fusion" do
      assert length(Search.rrf_combine(@vector_only, @keyword_only, 2, 60, {0.9, 0.1})) == 2
    end
  end
end
