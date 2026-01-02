defmodule Arcana.TestRepo.Migrations.CreateArcanaTables do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    create table(:arcana_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text
      add :content_type, :string, default: "text/plain"
      add :source_id, :string
      add :file_path, :string
      add :metadata, :map, default: %{}
      add :status, :string, default: "pending"
      add :error, :text
      add :chunk_count, :integer, default: 0

      timestamps()
    end

    create table(:arcana_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :text, :text, null: false
      add :embedding, :vector, size: 384, null: false
      add :chunk_index, :integer, default: 0
      add :token_count, :integer
      add :metadata, :map, default: %{}
      add :document_id, references(:arcana_documents, type: :binary_id, on_delete: :delete_all)

      timestamps()
    end

    create index(:arcana_chunks, [:document_id])
    create index(:arcana_documents, [:source_id])

    execute """
    CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
    USING hnsw (embedding vector_cosine_ops)
    """
  end

  def down do
    drop table(:arcana_chunks)
    drop table(:arcana_documents)
    execute "DROP EXTENSION IF EXISTS vector"
  end
end
