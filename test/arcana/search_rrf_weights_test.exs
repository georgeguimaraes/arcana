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

      assert length(results) == 4, "a zero weight must not drop the items"

      scored = Map.new(results, &{&1.id, &1.score})

      assert scored["k1"] == 0.0 and scored["k2"] == 0.0,
             "a zero-weighted side should contribute nothing"

      assert scored["v1"] > scored["k1"], "and the weighted side should outrank it"

      # Deliberately not asserting the order within the zero-weighted pair:
      # those scores tie, rrf_combine has no tiebreaker, and the final order
      # comes out of map enumeration. Pinning it would be testing an accident.
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

    test "equal weights keep the magnitudes unweighted RRF produced, not half of them" do
      # do_hybrid_rrf passes the 0.5/0.5 defaults, so without normalizing by the
      # larger weight every score on that path would silently halve - ordering
      # intact, but different numbers for anyone reading .score or its telemetry.
      unweighted = Search.rrf_combine(@vector_only, @keyword_only, 4, 60)
      defaults = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.5, 0.5})

      assert Enum.map(unweighted, & &1.score) == Enum.map(defaults, & &1.score)
    end

    test "the ratio is what matters, not the scale" do
      tenths = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.9, 0.1})
      whole = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {9, 1})

      assert ids(tenths) == ids(whole)

      # Equal within tolerance rather than identical: 0.1/0.9 and 1/9 differ by
      # one ULP, so the ratio survives normalization but the bits do not.
      for {a, b} <- Enum.zip(tenths, whole) do
        assert_in_delta a.score, b.score, 1.0e-15
      end
    end

    for bad <- [{nil, 0.5}, {0.5, nil}, {-1.0, 1.0}, {"0.5", 0.5}] do
      test "rejects #{inspect(bad)} instead of producing nonsense" do
        # Unvalidated, a nil crashed with ArithmeticError deep in the fusion and a
        # negative weight silently inverted that side's ranking.
        assert_raise ArgumentError, ~r/must be non-negative numbers/, fn ->
          Search.rrf_combine(@vector_only, @keyword_only, 4, 60, unquote(Macro.escape(bad)))
        end
      end
    end

    test "both weights zero means no preference rather than an arbitrary order" do
      zeroed = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {0.0, 0.0})
      equal = Search.rrf_combine(@vector_only, @keyword_only, 4, 60, {1.0, 1.0})

      assert Enum.map(zeroed, & &1.score) == Enum.map(equal, & &1.score)
    end

    test "limit still truncates after fusion" do
      assert length(Search.rrf_combine(@vector_only, @keyword_only, 2, 60, {0.9, 0.1})) == 2
    end
  end
end
