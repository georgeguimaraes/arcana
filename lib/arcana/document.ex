defmodule Arcana.Document do
  @moduledoc """
  Schema for documents stored in Arcana.

  Documents contain the original content and metadata,
  with associated chunks for vector search.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_documents" do
    field(:content, :string)
    field(:content_type, :string, default: "text/plain")
    field(:source_id, :string)
    field(:file_path, :string)
    field(:metadata, :map, default: %{})

    field(:status, Ecto.Enum,
      values: [:pending, :processing, :completed, :failed],
      default: :pending
    )

    field(:error, :string)
    field(:chunk_count, :integer, default: 0)

    has_many(:chunks, Arcana.Chunk)

    timestamps()
  end

  @required_fields [:content]
  @optional_fields [
    :content_type,
    :source_id,
    :file_path,
    :metadata,
    :status,
    :error,
    :chunk_count
  ]

  def changeset(document, attrs) do
    document
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
