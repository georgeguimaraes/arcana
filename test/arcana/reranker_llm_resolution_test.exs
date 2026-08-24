defmodule Arcana.RerankerLlmResolutionTest do
  @moduledoc """
  Where `Arcana.Reranker.LLM` gets its LLM from.

  `rerank/3` used `Keyword.fetch!(opts, :llm)`, so enabling the reranker through
  `Arcana.search/2` raised `KeyError` on an app that had an LLM configured all
  along - the workaround being to hand the library its own LLM back with
  `llm: Arcana.Config.get([], :llm)`. It now falls back to config the way
  `Arcana.ask/2` does.
  """
  use Arcana.DataCase, async: true

  alias Arcana.Reranker.LLM

  @chunks [
    %{id: "1", text: "Elixir runs on the BEAM"},
    %{id: "2", text: "Unrelated weather text"}
  ]

  defp scorer, do: fn _prompt -> {:ok, ~s({"1": 9, "2": 1})} end

  describe "llm resolution" do
    test "uses the configured llm when the call does not carry one" do
      put_arcana_env(:llm, scorer())

      assert {:ok, [%{id: "1"}]} = LLM.rerank("what runs on the BEAM?", @chunks, [])
    end

    test "a per-call llm wins over the configured one" do
      put_arcana_env(:llm, fn _ -> {:ok, ~s({"1": 1, "2": 9})} end)

      assert {:ok, [%{id: "1"}]} = LLM.rerank("q", @chunks, llm: scorer())
    end

    test "explains itself when there is no llm anywhere" do
      # Previously a bare KeyError on :llm, which said nothing about how to
      # configure one.
      err =
        assert_raise ArgumentError, fn ->
          LLM.rerank("q", @chunks, [])
        end

      assert err.message =~ "needs an LLM"
      assert err.message =~ "config :arcana, llm:"
    end

    test "reaches the reranker through Arcana.search/2 with only config set" do
      # The shape from the issue: reranker named in the search opts, LLM only in
      # config. This raised before.
      put_arcana_env(:llm, scorer())
      {:ok, _} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)

      assert {:ok, results} =
               Arcana.search("functional programming",
                 repo: Repo,
                 reranker: {LLM, []}
               )

      # Asserting on :rerank_score, not just {:ok, _}: a bare shape check would
      # also pass if reranking were silently skipped, which is the thing this
      # test exists to notice.
      assert Enum.all?(results, &is_number(&1.rerank_score)),
             "every returned chunk should carry the score the reranker gave it"
    end

    test "and with the llm inside the reranker tuple" do
      # This form already worked - Keyword.merge keeps the tuple's :llm when the
      # top-level opts have none - so it is pinned rather than fixed.
      {:ok, _} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)

      assert {:ok, results} =
               Arcana.search("functional programming",
                 repo: Repo,
                 reranker: {LLM, llm: scorer()}
               )

      assert Enum.all?(results, &is_number(&1.rerank_score))
    end
  end

  describe "filtering" do
    test "drops chunks below the threshold rather than reordering them" do
      # The contract the docs now state plainly: a chunk that was in the results
      # can be absent afterwards.
      llm = fn _ -> {:ok, ~s({"1": 9, "2": 3})} end

      assert {:ok, [%{id: "1"}]} = LLM.rerank("q", @chunks, llm: llm, threshold: 7)
    end

    test "threshold 0 reorders without dropping anything" do
      llm = fn _ -> {:ok, ~s({"1": 3, "2": 9})} end

      assert {:ok, [%{id: "2"}, %{id: "1"}]} =
               LLM.rerank("q", @chunks, llm: llm, threshold: 0)
    end
  end
end
