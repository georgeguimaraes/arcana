defmodule Arcana.TestRepo.Migrations.AddEvaluationTables do
  use Ecto.Migration

  def change do
    create table(:arcana_evaluation_test_cases, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:question, :text, null: false)
      add(:source, :string, null: false, default: "synthetic")
      add(:source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all))

      timestamps()
    end

    create table(:arcana_evaluation_test_case_chunks, primary_key: false) do
      add(
        :test_case_id,
        references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false)
    end

    create(unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id]))

    create table(:arcana_evaluation_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:status, :string, null: false, default: "running")
      add(:metrics, :map, default: %{})
      add(:results, :map, default: %{})
      add(:config, :map, default: %{})
      add(:test_case_count, :integer, default: 0)

      timestamps()
    end

    create(index(:arcana_evaluation_runs, [:inserted_at]))
  end
end
