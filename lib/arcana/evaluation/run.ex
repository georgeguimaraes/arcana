defmodule Arcana.Evaluation.Run do
  @moduledoc """
  An evaluation run containing metrics and per-case results.

  Stores the configuration used, aggregate metrics, and detailed
  results for each test case to enable drill-down into failures.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_evaluation_runs" do
    field(:status, Ecto.Enum, values: [:running, :completed, :failed], default: :running)
    field(:metrics, :map, default: %{})
    field(:results, :map, default: %{})
    field(:config, :map, default: %{})
    field(:test_case_count, :integer, default: 0)

    timestamps()
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :metrics, :results, :config, :test_case_count])
  end
end
