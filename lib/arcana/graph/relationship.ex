defmodule Arcana.Graph.Relationship do
  @moduledoc """
  Schema for knowledge graph relationships between entities.

  Relationships connect two entities with a typed edge,
  optionally including a description and strength score.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.Graph.Entity

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_graph_relationships" do
    field(:type, :string)
    field(:description, :string)
    field(:strength, :integer)
    field(:metadata, :map, default: %{})

    belongs_to(:source, Entity)
    belongs_to(:target, Entity)

    timestamps()
  end

  @required_fields [:type, :source_id, :target_id]
  @optional_fields [:description, :strength, :metadata]

  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:strength, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:target_id)
  end
end
