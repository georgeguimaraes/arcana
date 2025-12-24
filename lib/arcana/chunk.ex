defmodule Arcana.Chunk do
  @moduledoc """
  Schema for document chunks with embeddings.

  Chunks are the unit of storage for vector search,
  containing text segments and their embeddings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_chunks" do
    field :text, :string
    field :embedding, Pgvector.Ecto.Vector
    field :chunk_index, :integer, default: 0
    field :token_count, :integer
    field :metadata, :map, default: %{}

    belongs_to :document, Arcana.Document

    timestamps()
  end

  @required_fields [:text, :embedding]
  @optional_fields [:chunk_index, :token_count, :metadata, :document_id]

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:document_id)
  end
end
