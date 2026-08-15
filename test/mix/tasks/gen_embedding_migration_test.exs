defmodule Mix.Tasks.Arcana.Gen.EmbeddingMigrationTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Arcana.Gen.EmbeddingMigration

  test "creates the HNSW index via raw SQL with the opclass, not Ecto options" do
    content = EmbeddingMigration.migration_content(1024)

    assert content =~ "size: 1024"

    assert content =~ "CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks"
    assert content =~ "USING hnsw (embedding vector_cosine_ops)"

    # The old form rendered :options as a WITH (...) clause, which Postgres rejects
    refute content =~ ~s|options: "vector_cosine_ops"|
    refute content =~ "using: :hnsw"
    refute content =~ "create index("
  end

  test "drops the install migration's index name, plus the Ecto default defensively" do
    content = EmbeddingMigration.migration_content(768)

    assert content =~ ~s|execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"|
    assert content =~ ~s|execute "DROP INDEX IF EXISTS arcana_chunks_embedding_index"|

    # The old drop targeted the Ecto-default name and silently matched nothing
    refute content =~ "drop_if_exists index("
  end

  test "generated migration is valid Elixir" do
    assert {:ok, _ast} = Code.string_to_quoted(EmbeddingMigration.migration_content(512))
  end
end
