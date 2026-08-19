defmodule Arcana.VectorStore.PgvectorEfSearchTest do
  @moduledoc """
  Covers `:hnsw_ef_search`, which sets pgvector's `hnsw.ef_search` for a search.

  These assert that the setting reaches the connection the query runs on, not
  that it changes which rows come back. Observing the behaviour would mean
  crowding the shared HNSW index to make a filtered search under-return, which
  is the flake removed in #158 - and `enable_indexscan: "off"` on the test repo
  makes an index scan impossible here anyway.

  Because the setting is applied with `set_config(..., true)`, its scope is the
  surrounding transaction. In a sandboxed test that is the test's own
  transaction, so reading `current_setting/2` after the search is a direct
  observation of what the search did to that connection.
  """
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.VectorStore.Pgvector
  alias Ecto.Adapters.SQL

  @embedding List.duplicate(0.0, 383) ++ [1.0]

  defp current_ef_search do
    %{rows: [[value]]} =
      SQL.query!(Repo, "SELECT current_setting('hnsw.ef_search', true)", [])

    value
  end

  defp seed(collection_name) do
    {:ok, collection} = Collection.get_or_create(collection_name, Repo)

    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{content: "c", status: :completed, collection_id: collection.id})
      |> Repo.insert()

    {:ok, _} =
      %Chunk{}
      |> Chunk.changeset(%{text: "only chunk", embedding: @embedding, document_id: doc.id})
      |> Repo.insert()

    collection_name
  end

  describe "hnsw_ef_search" do
    test "is applied to the connection the search runs on" do
      collection = seed("ef-vector")

      results = Pgvector.search(collection, @embedding, repo: Repo, hnsw_ef_search: 123)

      assert length(results) == 1, "the search itself must still work"

      assert current_ef_search() == "123",
             "hnsw.ef_search was not set on the connection the query used"
    end

    test "is left alone when the option is absent" do
      collection = seed("ef-absent")

      # Warm the connection first: until something uses the vector type,
      # pgvector's GUCs are not registered and current_setting/2 reports NULL
      # rather than the default, so a before/after comparison would differ for a
      # reason that has nothing to do with the search.
      SQL.query!(Repo, "SELECT '[1,0,0]'::vector <=> '[0,1,0]'::vector", [])
      before = current_ef_search()

      assert [_] = Pgvector.search(collection, @embedding, repo: Repo)

      # Compared against what it was, not against a hardcoded 40 - pgvector owns
      # its default and is free to change it.
      assert current_ef_search() == before,
             "hnsw.ef_search should be untouched when :hnsw_ef_search is not given"
    end

    test "reaches the backend through Arcana.search/2, not just a direct call" do
      # The option has to survive Arcana.Search building the backend opts. A
      # backend that honours it is useless if the plumbing drops it on the way.
      seed("ef-through-search")

      {:ok, _results} =
        Arcana.search("only chunk",
          repo: Repo,
          collections: ["ef-through-search"],
          hnsw_ef_search: 321
        )

      assert current_ef_search() == "321",
             "the option did not survive Arcana.search/2 into the backend"
    end

    test "applies on the hybrid path too, which builds its own SQL" do
      seed("ef-hybrid")

      results =
        Pgvector.search_hybrid("ef-hybrid", @embedding, "only chunk",
          repo: Repo,
          hnsw_ef_search: 222
        )

      assert is_list(results)

      assert current_ef_search() == "222",
             "search_hybrid/4 does not share search/3's query, so it needs its own wrap"
    end

    test "can be set as a global search default rather than per call" do
      # config.ex documents it in the search defaults block, and a documented
      # option nothing reads is the exact gap this closes - so the config path
      # gets its own test rather than resting on merge_app_opts looking right.
      seed("ef-config-default")
      put_arcana_env(:search, hnsw_ef_search: 456)

      {:ok, _} =
        Arcana.search("only chunk", repo: Repo, collections: ["ef-config-default"])

      assert current_ef_search() == "456",
             "a global search default for :hnsw_ef_search never reached the backend"
    end

    test "rejects a bad value even when the collection resolves to nothing" do
      # Under strict mode an unknown collection returns early, so validating
      # inside that branch meant the same bad option raised or didn't depending
      # on whether the name happened to exist.
      put_arcana_env(:strict_collections, true)

      assert_raise ArgumentError, ~r/:hnsw_ef_search must be an integer in 1\.\.1000/, fn ->
        Pgvector.search("no-such-collection", @embedding, repo: Repo, hnsw_ef_search: -5)
      end
    end

    test "accepts the top of pgvector's range" do
      collection = seed("ef-max")

      assert [_] = Pgvector.search(collection, @embedding, repo: Repo, hnsw_ef_search: 1000)
      assert current_ef_search() == "1000"
    end

    test "rejects above pgvector's range instead of letting it degrade silently" do
      # 1001+ is where it gets nasty: on a connection that has already loaded
      # pgvector this raises a bare Postgrex.Error, but on a fresh one set_config
      # succeeds against a placeholder GUC and is silently reset to the default
      # when the query loads pgvector - so the search quietly runs at the recall
      # this option was set to avoid.
      assert_raise ArgumentError, ~r/must be an integer in 1\.\.1000/, fn ->
        Pgvector.search("ef-too-big", @embedding, repo: Repo, hnsw_ef_search: 1001)
      end
    end

    for bad <- [0, -1, "100", 100.0] do
      test "rejects #{inspect(bad)}" do
        assert_raise ArgumentError, ~r/:hnsw_ef_search must be an integer in 1\.\.1000/, fn ->
          Pgvector.search("ef-bad", @embedding, repo: Repo, hnsw_ef_search: unquote(bad))
        end
      end
    end
  end
end
