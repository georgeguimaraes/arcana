defmodule Arcana.CollectionTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection

  describe "Collection schema" do
    test "creates a collection with name" do
      changeset = Collection.changeset(%Collection{}, %{name: "products"})
      assert changeset.valid?
    end

    test "requires name" do
      changeset = Collection.changeset(%Collection{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "enforces unique name" do
      {:ok, _} =
        %Collection{}
        |> Collection.changeset(%{name: "unique-collection"})
        |> Arcana.TestRepo.insert()

      {:error, changeset} =
        %Collection{}
        |> Collection.changeset(%{name: "unique-collection"})
        |> Arcana.TestRepo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end

    test "allows optional description" do
      changeset =
        Collection.changeset(%Collection{}, %{
          name: "products",
          description: "Product documentation"
        })

      assert changeset.valid?
      assert changeset.changes.description == "Product documentation"
    end
  end

  describe "get_or_create_collection/2" do
    test "creates new collection if it doesn't exist" do
      assert {:ok, collection} = Collection.get_or_create("new-collection", Arcana.TestRepo)
      assert collection.name == "new-collection"
    end

    test "returns existing collection if it exists" do
      {:ok, original} =
        %Collection{}
        |> Collection.changeset(%{name: "existing"})
        |> Arcana.TestRepo.insert()

      assert {:ok, found} = Collection.get_or_create("existing", Arcana.TestRepo)
      assert found.id == original.id
    end

    test "creates default collection when name is 'default'" do
      assert {:ok, collection} = Collection.get_or_create("default", Arcana.TestRepo)
      assert collection.name == "default"
    end
  end
end
