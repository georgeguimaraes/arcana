defmodule Arcana.Graph.RelationshipEvidence do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.Chunk
  alias Arcana.Graph.Relationship

  @unique_index :arcana_graph_relationship_evidence_rel_chunk_index

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_graph_relationship_evidence" do
    belongs_to(:relationship, Relationship)
    belongs_to(:chunk, Chunk)

    timestamps(updated_at: false)
  end

  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [:relationship_id, :chunk_id])
    |> validate_required([:relationship_id, :chunk_id])
    |> foreign_key_constraint(:relationship_id)
    |> foreign_key_constraint(:chunk_id)
    |> unique_constraint([:relationship_id, :chunk_id], name: @unique_index)
  end
end
