defmodule Arcana.Graph.Community do
  @moduledoc """
  Schema for knowledge graph communities.

  Communities are clusters of related entities detected by the
  Leiden algorithm. They enable global queries by providing
  pre-generated summaries at different hierarchy levels.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.Collection

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_graph_communities" do
    field(:level, :integer)
    field(:description, :string)
    field(:summary, :string)
    field(:entity_ids, {:array, :binary_id}, default: [])
    field(:dirty, :boolean, default: true)
    field(:change_count, :integer, default: 0)

    belongs_to(:collection, Collection)

    timestamps()
  end

  @required_fields [:level]
  @optional_fields [:description, :summary, :entity_ids, :dirty, :change_count, :collection_id]

  def changeset(community, attrs) do
    community
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:level, greater_than_or_equal_to: 0)
    |> validate_number(:change_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:collection_id)
  end
end
