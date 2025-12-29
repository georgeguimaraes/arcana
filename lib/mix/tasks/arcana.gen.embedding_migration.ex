defmodule Mix.Tasks.Arcana.Gen.EmbeddingMigration do
  @moduledoc """
  Generates a migration to update vector column dimensions.

  Use this when switching to an embedding model with different dimensions.

      $ mix arcana.gen.embedding_migration

  The task will:
  1. Detect the current embedding configuration dimensions
  2. Show the detected dimensions
  3. Generate a migration to update the vector column

  ## Options

    * `--dimensions` - Override auto-detected dimensions

  """

  use Mix.Task

  @shortdoc "Generates a migration for embedding dimension changes"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dimensions: :integer]
      )

    # Start the app to access config
    Mix.Task.run("app.config")

    dimensions =
      case Keyword.get(opts, :dimensions) do
        nil ->
          case detect_dimensions() do
            {:ok, dims} ->
              Mix.shell().info("Detected embedding dimensions: #{dims}")
              dims

            {:error, reason} ->
              Mix.raise("Could not detect dimensions: #{inspect(reason)}")
          end

        dims ->
          Mix.shell().info("Using specified dimensions: #{dims}")
          dims
      end

    generate_migration(dimensions)
  end

  defp detect_dimensions do
    embedder = Arcana.embedder()
    {:ok, Arcana.Embedder.dimensions(embedder)}
  rescue
    e -> {:error, e}
  end

  defp generate_migration(dimensions) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_update_embedding_dimensions.exs"

    # Find the priv/repo/migrations directory
    repo_config = Application.get_env(:arcana, Application.get_env(:arcana, :repo))
    priv_dir = Keyword.get(repo_config, :priv, "priv/repo")
    migrations_dir = Path.join(priv_dir, "migrations")

    # Ensure the directory exists
    File.mkdir_p!(migrations_dir)

    path = Path.join(migrations_dir, filename)

    content = migration_content(dimensions)

    File.write!(path, content)

    Mix.shell().info("""

    Generated migration: #{path}

    This migration will:
    1. Drop the HNSW index on the embedding column
    2. Alter the embedding column to #{dimensions} dimensions
    3. Recreate the HNSW index

    Run the migration with:

        mix ecto.migrate

    After migrating, re-embed all documents with:

        mix arcana.reembed

    """)
  end

  defp migration_content(dimensions) do
    """
    defmodule Arcana.Repo.Migrations.UpdateEmbeddingDimensions do
      use Ecto.Migration

      def up do
        # Drop the existing HNSW index
        drop_if_exists index(:arcana_chunks, [:embedding])

        # Alter the embedding column to new dimensions
        alter table(:arcana_chunks) do
          modify :embedding, :vector, size: #{dimensions}
        end

        # Recreate the HNSW index with the new dimensions
        create index(:arcana_chunks, [:embedding],
          using: :hnsw,
          options: "vector_cosine_ops"
        )
      end

      def down do
        # Note: Down migration requires knowing the previous dimensions
        # This is a best-effort reversal - you may need to adjust the size
        drop_if_exists index(:arcana_chunks, [:embedding])

        alter table(:arcana_chunks) do
          modify :embedding, :vector, size: 384
        end

        create index(:arcana_chunks, [:embedding],
          using: :hnsw,
          options: "vector_cosine_ops"
        )
      end
    end
    """
  end
end
