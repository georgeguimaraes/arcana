defmodule Arcana.VectorStore.PgvectorHybridKeywordTest do
  @moduledoc """
  How hybrid search turns a ts_rank into a keyword contribution.

  Every chunk here is seeded with the *same* embedding, so vector scores tie and
  any difference in ranking or score comes from the keyword side alone. That is
  the only way to test this without a corpus: the bug in #166 was visible as
  "hybrid ranks worse than pure vector", which needs real documents, while the
  mechanism underneath is exactly reproducible.

  Two things are being pinned:

    * `ts_rank` scores term overlap, not whether the query matched. For
      `plainto_tsquery('english', 'what sheens does Duration come in')`, which is
      `'sheen' & 'durat' & 'come'`, a chunk carrying two of the three scores
      ~0.097 while satisfying the query not at all. Hybrid used to let that
      compete; keyword mode never did, because it gates on `@@`.
    * Normalizing against the best hit in the set maps that best hit to 1.0
      however weak it is, so "nothing really matched" became a full-weight
      signal.
  """
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.VectorStore.Pgvector

  @query "what sheens does Duration come in"
  @embedding List.duplicate(0.0, 383) ++ [1.0]

  defp seed(collection_name, texts) do
    {:ok, collection} = Collection.get_or_create(collection_name, Repo)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{content: "c", status: :completed, collection_id: collection.id})
      |> Repo.insert()

    for {text, index} <- Enum.with_index(texts) do
      {:ok, _} =
        %Chunk{}
        |> Chunk.changeset(%{
          text: text,
          embedding: @embedding,
          chunk_index: index,
          document_id: doc.id
        })
        |> Repo.insert()
    end

    collection_name
  end

  defp search(collection, opts) do
    Pgvector.search_hybrid(collection, @embedding, @query, Keyword.put(opts, :repo, Repo))
  end

  defp by_text(results) do
    Map.new(results, fn r -> {r.metadata[:text], r} end)
  end

  describe "keyword scoring" do
    test "a chunk that does not satisfy the query contributes nothing" do
      partial = "This paint comes in several sheens including satin"
      full = "Duration paint sheens come in satin"

      collection = seed("kw-gate", [partial, full])
      results = search(collection, []) |> by_text()

      assert results[partial].metadata[:keyword_score] == 0.0,
             "two of three query terms does not satisfy 'sheen & durat & come', " <>
               "so it must not score at all"

      assert results[full].metadata[:keyword_score] > 0.0,
             "the chunk that does satisfy the query should still score"
    end

    test "a term-dense non-match does not outrank the chunk that answers the query" do
      # The shape reported in #166. ts_rank rewards term frequency, so a chunk
      # repeating two of the three query terms scores 0.93 while satisfying the
      # query not at all, and the genuine sparse match scores 0.20. Normalizing
      # against the set handed the 0.93 a perfect 1.0 and put it first.
      dense_non_match =
        "Sheens sheens sheens. Come come come. Which sheens come next, " <>
          "and which sheens come after? Sheens come often."

      genuine = "Duration is available in several finishes; ask which sheens come standard."

      collection = seed("kw-gate-order", [dense_non_match, genuine])
      results = search(collection, [])

      assert hd(results).metadata[:text] == genuine,
             "with vector scores tied, the chunk that satisfies the query must rank first"

      by = by_text(results)

      assert by[dense_non_match].metadata[:keyword_score] == 0.0,
             "it never satisfied 'sheen & durat & come', so its term density is irrelevant"
    end

    test "a weak best-in-set is damped rather than stretched to a perfect score" do
      # One genuine match, nothing else. Its own ts_rank is the set maximum, so
      # normalizing against the set would hand it 1.0 no matter how weak it is.
      only_match = "Duration paint sheens come in satin"
      collection = seed("kw-floor", [only_match, "Completely unrelated text about indexing"])

      unfloored = search(collection, keyword_score_floor: 0.0) |> by_text()
      damped = search(collection, keyword_score_floor: 1.0) |> by_text()

      raw = unfloored[only_match].metadata[:keyword_score]
      assert raw > 0.0 and raw < 1.0, "precondition: a real but sub-1.0 ts_rank"

      # floor 0 is the old behaviour: normalize against the set's own best, so
      # the best hit lands on 1.0 whatever its absolute score. With vector tied
      # at 1.0 and even weights, that is the maximum blended score reachable.
      assert_in_delta unfloored[only_match].score, 1.0, 0.0001

      assert damped[only_match].score < unfloored[only_match].score,
             "a floor above the set's best score must reduce its contribution"
    end

    test "a set with a strong match is unaffected by the default floor" do
      strong = "Duration paint sheens come in satin gloss flat eggshell finish options"
      collection = seed("kw-strong", [strong, "Unrelated text about database indexing"])

      with_default = search(collection, []) |> by_text()
      without_floor = search(collection, keyword_score_floor: 0.0) |> by_text()

      assert_in_delta with_default[strong].score,
                      without_floor[strong].score,
                      0.0001,
                      "a genuine match scores above the floor, so the floor is inert"
    end

    test "a query of only stopwords scores nothing rather than dividing by zero" do
      collection = seed("kw-stopwords", ["Duration paint sheens", "Unrelated text"])

      results =
        Pgvector.search_hybrid(collection, @embedding, "the and of", repo: Repo)

      assert Enum.all?(results, &(&1.metadata[:keyword_score] == 0.0)),
             "an empty tsquery matches nothing, so nothing should score"
    end

    test "opting out of the floor on a set where nothing matched is not a divide by zero" do
      # floor 0 means "scale against the set's own best", and with no matches at
      # all that best is 0. The old min = max branch absorbed this; the divisor
      # form needs its own guard, and Postgres raises 22012 without one.
      collection = seed("kw-divzero", ["totally unrelated text", "also unrelated"])

      results =
        Pgvector.search_hybrid(collection, @embedding, "zzzznomatchzzzz",
          repo: Repo,
          keyword_score_floor: 0.0
        )

      assert length(results) == 2
      assert Enum.all?(results, &(&1.metadata[:keyword_score] == 0.0))
    end

    for bad <- [-0.1, 1.5, "0.05", nil] do
      test "rejects a floor of #{inspect(bad)}" do
        assert_raise ArgumentError, ~r/:keyword_score_floor must be a number/, fn ->
          Pgvector.search_hybrid("kw-bad", @embedding, @query,
            repo: Repo,
            keyword_score_floor: unquote(bad)
          )
        end
      end
    end
  end
end
