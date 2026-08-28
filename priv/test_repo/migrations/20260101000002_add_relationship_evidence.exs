defmodule Arcana.TestRepo.Migrations.AddRelationshipEvidence do
  use Ecto.Migration

  def up do
    # v1 relationships have no chunk provenance, so they cannot be backfilled
    # without making failed or replaced documents visible again. Keep the test
    # repo's upgrade behavior aligned with Arcana.Graph.Migration v2.
    execute("DELETE FROM arcana_graph_relationships")

    execute(
      "UPDATE arcana_graph_communities " <>
        "SET dirty = true, summary = NULL, summary_fingerprint = NULL"
    )

    alter table(:arcana_graph_relationships) do
      add(:fingerprint, :string, null: false)
    end

    create(unique_index(:arcana_graph_relationships, [:fingerprint]))

    create table(:arcana_graph_relationship_evidence, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :relationship_id,
        references(:arcana_graph_relationships, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :chunk_id,
        references(:arcana_chunks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      timestamps(updated_at: false)
    end

    create(
      unique_index(:arcana_graph_relationship_evidence, [:relationship_id, :chunk_id],
        name: :arcana_graph_relationship_evidence_rel_chunk_index
      )
    )

    create(index(:arcana_graph_relationship_evidence, [:chunk_id]))
  end

  def down do
    drop(table(:arcana_graph_relationship_evidence))
    drop(index(:arcana_graph_relationships, [:fingerprint]))

    alter table(:arcana_graph_relationships) do
      remove(:fingerprint)
    end
  end
end
