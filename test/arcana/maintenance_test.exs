defmodule Arcana.MaintenanceTest do
  use Arcana.DataCase, async: true

  alias Arcana.Maintenance

  describe "strict collections" do
    test "reembed/2 errors on an unknown collection" do
      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.reembed(Repo, collection: "strict-nope", strict_collections: true)
    end

    test "embed_entities/2 errors on an unknown collection instead of embedding globally" do
      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.embed_entities(Repo,
                 collection: "strict-nope",
                 strict_collections: true
               )
    end

    test "graph maintenance errors on an unknown collection instead of succeeding with zero work" do
      opts = [collection: "strict-nope", strict_collections: true]

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.rebuild_graph(Repo, opts)

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.detect_communities(Repo, opts)

      assert {:error, {:unknown_collection, "strict-nope"}} =
               Maintenance.summarize_communities(
                 Repo,
                 opts ++ [llm: fn _p, _c, _o -> {:ok, "summary"} end]
               )
    end

    test "graph maintenance reports zero work for unknown collections when strict is off" do
      assert {:ok, %{collections: 0}} = Maintenance.rebuild_graph(Repo, collection: "nope")
    end
  end
end
