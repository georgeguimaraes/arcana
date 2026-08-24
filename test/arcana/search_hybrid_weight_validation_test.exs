defmodule Arcana.SearchHybridWeightValidationTest do
  @moduledoc """
  Both hybrid backends have to reject the same weights.

  The two paths compute hybrid scores in completely different places: pgvector
  multiplies `:vector_weight`/`:keyword_weight` into SQL and compares the result
  against `:threshold`, while every other backend fuses ranks in Elixir through
  `rrf_combine/5`. Validating inside the fusion helper covered only the second
  one, so the default backend still accepted a negative weight (silently
  inverting that side) and turned `{0.0, 0.0}` into zero results where rank
  fusion returned everything. Same call, opposite outcome, per backend.
  """
  use Arcana.DataCase, async: true

  alias Arcana.VectorStore.Memory

  setup do
    {:ok, _} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
    {:ok, _} = Arcana.ingest("Python is great for machine learning.", repo: Repo)
    :ok
  end

  defp backends do
    {:ok, pid} = Memory.start_link([])
    [pgvector: :pgvector, rank_fusion: {:memory, pid: pid}]
  end

  describe "weight validation is backend-independent" do
    test "a negative weight is rejected on every hybrid backend" do
      for {_name, store} <- backends() do
        assert_raise ArgumentError, ~r/must be non-negative numbers/, fn ->
          Arcana.search("programming",
            repo: Repo,
            mode: :hybrid,
            graph: false,
            vector_store: store,
            vector_weight: -1.0,
            keyword_weight: 1.0
          )
        end
      end
    end

    test "both weights zero is rejected on every hybrid backend" do
      for {_name, store} <- backends() do
        assert_raise ArgumentError, ~r/cannot both be zero/, fn ->
          Arcana.search("programming",
            repo: Repo,
            mode: :hybrid,
            graph: false,
            vector_store: store,
            vector_weight: 0.0,
            keyword_weight: 0.0
          )
        end
      end
    end

    test "a non-numeric weight is rejected on every hybrid backend" do
      for {_name, store} <- backends() do
        assert_raise ArgumentError, ~r/must be non-negative numbers/, fn ->
          Arcana.search("programming",
            repo: Repo,
            mode: :hybrid,
            graph: false,
            vector_store: store,
            vector_weight: "0.5",
            keyword_weight: 0.5
          )
        end
      end
    end

    test "legitimate unequal weights still search on every hybrid backend" do
      # The guard rejects nonsense, not weighting itself.
      for {_name, store} <- backends() do
        assert {:ok, _results} =
                 Arcana.search("programming",
                   repo: Repo,
                   mode: :hybrid,
                   graph: false,
                   vector_store: store,
                   vector_weight: 0.9,
                   keyword_weight: 0.1
                 )
      end
    end
  end
end
