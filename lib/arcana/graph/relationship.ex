defmodule Arcana.Graph.Relationship do
  @moduledoc """
  Schema for knowledge graph relationships between entities.

  Relationships connect two entities with a typed edge,
  optionally including a description and strength score.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.Graph.{Entity, RelationshipEvidence}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_graph_relationships" do
    field(:type, :string)
    field(:description, :string)
    field(:strength, :integer)
    field(:metadata, :map, default: %{})
    field(:fingerprint, :string)

    belongs_to(:source, Entity)
    belongs_to(:target, Entity)
    has_many(:evidence, RelationshipEvidence)

    timestamps()
  end

  @required_fields [:type, :source_id, :target_id, :fingerprint]
  @optional_fields [:description, :strength, :metadata]

  def changeset(relationship, attrs) do
    relationship
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> normalize_metadata()
    |> put_fingerprint()
    |> validate_required(@required_fields)
    |> validate_number(:strength, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:target_id)
  end

  defp put_fingerprint(changeset) do
    attrs = %{
      source_id: get_field(changeset, :source_id),
      target_id: get_field(changeset, :target_id),
      type: get_field(changeset, :type),
      description: get_field(changeset, :description),
      strength: get_field(changeset, :strength),
      metadata: get_field(changeset, :metadata) || %{}
    }

    if attrs.source_id && attrs.target_id && attrs.type do
      put_change(changeset, :fingerprint, fingerprint(attrs))
    else
      changeset
    end
  end

  defp normalize_metadata(changeset) do
    put_change(changeset, :metadata, normalized_metadata(get_field(changeset, :metadata)))
  end

  @doc false
  def fingerprint(attrs) do
    fact = {
      attrs.source_id,
      attrs.target_id,
      attrs.type,
      attrs[:description],
      attrs[:strength],
      normalized_metadata(attrs[:metadata])
    }

    fact
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def normalized_metadata(nil), do: %{}

  def normalized_metadata(metadata) do
    case Jason.encode(metadata) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _reason} -> metadata
    end
  end
end
