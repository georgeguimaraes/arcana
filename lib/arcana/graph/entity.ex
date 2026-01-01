defmodule Arcana.Graph.Entity do
  @moduledoc """
  Schema for knowledge graph entities.

  Entities represent named concepts, people, places, organizations,
  or other items extracted from documents for graph-based retrieval.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.{Chunk, Collection}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @entity_types [:person, :organization, :location, :event, :concept, :technology, :other]

  schema "arcana_graph_entities" do
    field(:name, :string)
    field(:type, Ecto.Enum, values: @entity_types)
    field(:description, :string)
    field(:embedding, Pgvector.Ecto.Vector)
    field(:metadata, :map, default: %{})

    belongs_to(:chunk, Chunk)
    belongs_to(:collection, Collection)

    timestamps()
  end

  @required_fields [:name, :type]
  @optional_fields [:description, :embedding, :metadata, :chunk_id, :collection_id]

  def changeset(entity, attrs) do
    entity
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:chunk_id)
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint([:name, :collection_id])
  end
end
