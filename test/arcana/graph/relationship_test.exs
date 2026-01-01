defmodule Arcana.Graph.RelationshipTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Entity, Relationship}

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        Relationship.changeset(%Relationship{}, %{
          type: "WORKS_FOR",
          source_id: Ecto.UUID.generate(),
          target_id: Ecto.UUID.generate()
        })

      assert changeset.valid?
    end

    test "valid with all fields" do
      changeset =
        Relationship.changeset(%Relationship{}, %{
          type: "WORKS_FOR",
          description: "Sam Altman is CEO of OpenAI",
          strength: 9,
          source_id: Ecto.UUID.generate(),
          target_id: Ecto.UUID.generate(),
          metadata: %{"since" => "2019"}
        })

      assert changeset.valid?
    end

    test "invalid without type" do
      changeset =
        Relationship.changeset(%Relationship{}, %{
          source_id: Ecto.UUID.generate(),
          target_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).type
    end

    test "invalid without source_id" do
      changeset =
        Relationship.changeset(%Relationship{}, %{
          type: "WORKS_FOR",
          target_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source_id
    end

    test "invalid without target_id" do
      changeset =
        Relationship.changeset(%Relationship{}, %{
          type: "WORKS_FOR",
          source_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).target_id
    end

    test "validates strength range 1-10" do
      base_attrs = %{
        type: "WORKS_FOR",
        source_id: Ecto.UUID.generate(),
        target_id: Ecto.UUID.generate()
      }

      changeset = Relationship.changeset(%Relationship{}, Map.put(base_attrs, :strength, 0))
      refute changeset.valid?
      assert "must be greater than or equal to 1" in errors_on(changeset).strength

      changeset = Relationship.changeset(%Relationship{}, Map.put(base_attrs, :strength, 11))
      refute changeset.valid?
      assert "must be less than or equal to 10" in errors_on(changeset).strength

      changeset = Relationship.changeset(%Relationship{}, Map.put(base_attrs, :strength, 5))
      assert changeset.valid?
    end
  end

  describe "database operations" do
    test "inserts relationship between entities" do
      {:ok, source} = create_entity("Sam Altman", :person)
      {:ok, target} = create_entity("OpenAI", :organization)

      {:ok, relationship} =
        %Relationship{}
        |> Relationship.changeset(%{
          type: "LEADS",
          description: "Sam Altman is CEO",
          strength: 10,
          source_id: source.id,
          target_id: target.id
        })
        |> Repo.insert()

      assert relationship.id
      assert relationship.type == "LEADS"
      assert relationship.source_id == source.id
      assert relationship.target_id == target.id
    end

    test "loads source and target entities" do
      {:ok, source} = create_entity("Sam Altman", :person)
      {:ok, target} = create_entity("OpenAI", :organization)

      {:ok, relationship} =
        %Relationship{}
        |> Relationship.changeset(%{
          type: "LEADS",
          source_id: source.id,
          target_id: target.id
        })
        |> Repo.insert()

      relationship = Repo.preload(relationship, [:source, :target])

      assert relationship.source.name == "Sam Altman"
      assert relationship.target.name == "OpenAI"
    end

    test "deletes relationship when source entity is deleted" do
      {:ok, source} = create_entity("Sam Altman", :person)
      {:ok, target} = create_entity("OpenAI", :organization)

      {:ok, _relationship} =
        %Relationship{}
        |> Relationship.changeset(%{
          type: "LEADS",
          source_id: source.id,
          target_id: target.id
        })
        |> Repo.insert()

      Repo.delete!(source)

      assert Repo.all(Relationship) == []
    end
  end

  defp create_entity(name, type) do
    %Entity{}
    |> Entity.changeset(%{name: name, type: type})
    |> Repo.insert()
  end
end
