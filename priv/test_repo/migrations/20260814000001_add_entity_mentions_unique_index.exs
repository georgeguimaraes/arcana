defmodule Arcana.TestRepo.Migrations.AddEntityMentionsUniqueIndex do
  use Ecto.Migration

  def up do
    # Remove duplicate mentions before adding the unique index,
    # keeping the oldest row per (entity_id, chunk_id) pair.
    execute("""
    DELETE FROM arcana_graph_entity_mentions m
    USING arcana_graph_entity_mentions kept
    WHERE m.entity_id = kept.entity_id
      AND m.chunk_id = kept.chunk_id
      AND m.ctid > kept.ctid
    """)

    create(unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id]))
  end

  def down do
    drop(unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id]))
  end
end
