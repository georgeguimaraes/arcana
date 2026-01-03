defmodule Arcana.Graph.EntityMention do
  @moduledoc """
  Schema for tracking where entities appear in chunks.

  Entity mentions link entities to the specific chunks where they
  were found, optionally with span positions and surrounding context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.{Chunk, Graph.Entity}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_graph_entity_mentions" do
    field(:span_start, :integer)
    field(:span_end, :integer)
    field(:context, :string)

    belongs_to(:entity, Entity)
    belongs_to(:chunk, Chunk)

    timestamps()
  end

  @required_fields [:entity_id, :chunk_id]
  @optional_fields [:span_start, :span_end, :context]

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:entity_id)
    |> foreign_key_constraint(:chunk_id)
  end
end
