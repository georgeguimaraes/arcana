defmodule Arcana.Evaluation.TestCase do
  @moduledoc """
  A test case for retrieval evaluation.

  Each test case contains a question and links to one or more
  chunks that are considered relevant (ground truth).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Arcana.Chunk

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_evaluation_test_cases" do
    field(:question, :string)
    field(:source, Ecto.Enum, values: [:synthetic, :manual], default: :synthetic)

    belongs_to(:source_chunk, Chunk)
    many_to_many(:relevant_chunks, Chunk, join_through: "arcana_evaluation_test_case_chunks")

    timestamps()
  end

  def changeset(test_case, attrs) do
    test_case
    |> cast(attrs, [:question, :source, :source_chunk_id])
    |> validate_required([:question])
  end
end
