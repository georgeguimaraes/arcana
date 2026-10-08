defmodule Arcana.VectorStore.PgvectorHybridKeywordTest do
  @moduledoc """
  How hybrid search turns the query's terms into a keyword contribution.

  Every chunk here is seeded with the *same* embedding, so vector scores tie and
  any difference in ranking or score comes from the keyword side alone. That is
  the only way to test this without a corpus: the bugs in #166 and in long
  queries were visible as "hybrid ranks no better than pure vector", which needs
  real documents, while the mechanism underneath is exactly reproducible.

  The keyword score is the share of the query's distinct lexemes a chunk
  contains. `what sheens does Duration come in` has three: `sheen`, `durat` and
  `come`. Two things are pinned:

    * A partial match counts in proportion to what it carries. Gating on the AND
      query made a chunk carry every term, so a long query matched nothing.
    * Repeating terms does not raise the score, so a term-dense chunk can't
      outrank the chunk that answers the query (#166), as it could under ts_rank.
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
    test "a chunk scores the share of the query's terms it carries" do
      partial = "This paint comes in several sheens including satin"
      full = "Duration paint sheens come in satin"

      collection = seed("kw-coverage", [partial, full])
      results = search(collection, []) |> by_text()

      assert_in_delta results[partial].metadata[:keyword_score], 2 / 3, 0.0001
      assert_in_delta results[full].metadata[:keyword_score], 1.0, 0.0001
    end

    test "a long query still scores the chunks that carry some of its terms" do
      # Agents write searches like this one. Under the AND gate no chunk held
      # all of its terms, so every keyword score was 0 and hybrid ran as vector.
      query = "Duration paint sheens satin gloss eggshell price warranty coverage stores delivery"
      some = "Duration comes in satin and eggshell sheens"

      collection = seed("kw-long", [some, "Completely unrelated text about indexing"])
      results = Pgvector.search_hybrid(collection, @embedding, query, repo: Repo) |> by_text()

      assert results[some].metadata[:keyword_score] > 0.0

      assert hd(Pgvector.search_hybrid(collection, @embedding, query, repo: Repo)).metadata[:text] ==
               some
    end

    test "a term-dense chunk does not outrank the chunk that answers the query" do
      # The shape reported in #166. ts_rank rewards term frequency, so a chunk
      # repeating two of the three query terms scored 0.93 and the genuine sparse
      # match 0.20. Coverage counts each term once: 2 of 3 against 3 of 3.
      dense =
        "Sheens sheens sheens. Come come come. Which sheens come next, " <>
          "and which sheens come after? Sheens come often."

      genuine = "Duration is available in several finishes; ask which sheens come standard."

      collection = seed("kw-dense", [dense, genuine])
      results = search(collection, [])

      assert hd(results).metadata[:text] == genuine,
             "with vector scores tied, the chunk that carries more of the query must rank first"

      by = by_text(results)
      assert by[dense].metadata[:keyword_score] < by[genuine].metadata[:keyword_score]
    end

    test "a query of only stopwords scores nothing rather than dividing by zero" do
      collection = seed("kw-stopwords", ["Duration paint sheens", "Unrelated text"])

      results =
        Pgvector.search_hybrid(collection, @embedding, "the and of", repo: Repo)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.metadata[:keyword_score] == 0.0))
    end

    test "the deprecated :keyword_score_floor is ignored with a warning" do
      collection = seed("kw-floor", ["Duration paint sheens come in satin"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [with_floor] = search(collection, keyword_score_floor: 1.0)
          assert [without_floor] = search(collection, [])
          assert with_floor.score == without_floor.score
          assert with_floor.metadata[:keyword_score] == without_floor.metadata[:keyword_score]
        end)

      assert log =~ ":keyword_score_floor is deprecated and ignored"
    end

    test "each deprecated option warns, even when several are passed" do
      collection = seed("kw-deprecated", ["Duration paint sheens come in satin"])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          search(collection, semantic_weight: 0.5, keyword_score_floor: 1.0)
        end)

      assert log =~ ":semantic_weight is deprecated"
      assert log =~ ":keyword_score_floor is deprecated"
    end
  end
end
