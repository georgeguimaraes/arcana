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
  end
end
