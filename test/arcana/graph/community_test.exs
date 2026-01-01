defmodule Arcana.Graph.CommunityTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection
  alias Arcana.Graph.{Community, Entity}

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Community.changeset(%Community{}, %{level: 0})

      assert changeset.valid?
    end

    test "valid with all fields" do
      entity_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      changeset =
        Community.changeset(%Community{}, %{
          level: 1,
          description: "AI companies cluster",
          summary: "This community contains AI research organizations...",
          entity_ids: entity_ids,
          dirty: false,
          change_count: 5
        })

      assert changeset.valid?
    end

    test "invalid without level" do
      changeset = Community.changeset(%Community{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).level
    end

    test "validates level is non-negative" do
      changeset = Community.changeset(%Community{}, %{level: -1})

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).level
    end

    test "validates change_count is non-negative" do
      changeset = Community.changeset(%Community{}, %{level: 0, change_count: -1})

      refute changeset.valid?
      assert "must be greater than or equal to 0" in errors_on(changeset).change_count
    end
  end

  describe "database operations" do
    test "inserts community with entity_ids array" do
      {:ok, entity1} = create_entity("OpenAI", :organization)
      {:ok, entity2} = create_entity("Sam Altman", :person)

      {:ok, community} =
        %Community{}
        |> Community.changeset(%{
          level: 0,
          description: "AI leadership",
          entity_ids: [entity1.id, entity2.id]
        })
        |> Repo.insert()

      assert community.id
      assert community.level == 0
      assert length(community.entity_ids) == 2
      assert entity1.id in community.entity_ids
      assert entity2.id in community.entity_ids
    end

    test "inserts community with collection association" do
      {:ok, collection} = create_collection()

      {:ok, community} =
        %Community{}
        |> Community.changeset(%{
          level: 0,
          collection_id: collection.id
        })
        |> Repo.insert()

      assert community.collection_id == collection.id
    end

    test "defaults dirty to true" do
      {:ok, community} =
        %Community{}
        |> Community.changeset(%{level: 0})
        |> Repo.insert()

      assert community.dirty == true
    end

    test "defaults change_count to 0" do
      {:ok, community} =
        %Community{}
        |> Community.changeset(%{level: 0})
        |> Repo.insert()

      assert community.change_count == 0
    end

    test "can mark community as clean" do
      {:ok, community} =
        %Community{}
        |> Community.changeset(%{level: 0})
        |> Repo.insert()

      {:ok, updated} =
        community
        |> Community.changeset(%{dirty: false, change_count: 0})
        |> Repo.update()

      assert updated.dirty == false
      assert updated.change_count == 0
    end

    test "deletes community when collection is deleted" do
      {:ok, collection} = create_collection()

      {:ok, _community} =
        %Community{}
        |> Community.changeset(%{level: 0, collection_id: collection.id})
        |> Repo.insert()

      Repo.delete!(collection)

      assert Repo.all(Community) == []
    end
  end

  describe "hierarchy levels" do
    test "supports multiple hierarchy levels" do
      {:ok, collection} = create_collection()

      {:ok, _level0} =
        %Community{}
        |> Community.changeset(%{
          level: 0,
          description: "Fine-grained",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, _level1} =
        %Community{}
        |> Community.changeset(%{level: 1, description: "Medium", collection_id: collection.id})
        |> Repo.insert()

      {:ok, _level2} =
        %Community{}
        |> Community.changeset(%{
          level: 2,
          description: "Broad themes",
          collection_id: collection.id
        })
        |> Repo.insert()

      communities = Repo.all(Community) |> Enum.sort_by(& &1.level)

      assert length(communities) == 3
      assert Enum.map(communities, & &1.level) == [0, 1, 2]
    end
  end

  defp create_collection(name \\ "test-collection") do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert()
  end

  defp create_entity(name, type) do
    %Entity{}
    |> Entity.changeset(%{name: name, type: type})
    |> Repo.insert()
  end
end
