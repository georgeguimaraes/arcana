defmodule Mix.Tasks.Arcana.Gen.EmbeddingMigration do
  @moduledoc """
  Generates a migration to update vector column dimensions.

  Use this when switching to an embedding model with different dimensions.

      $ mix arcana.gen.embedding_migration

  The task will:
  1. Detect the current embedding configuration dimensions
  2. Show the detected dimensions
  3. Generate a migration to update the vector column

  The `down` migration restores the dimensions the column had *before*
  this migration. Those are read from the database when it is reachable;
  otherwise pass `--previous-dimensions`. Without either, the generated
  `down` raises instead of silently truncating the column.

  ## Options

    * `--dimensions` - Override auto-detected dimensions
    * `--previous-dimensions` - Dimensions the `down` migration restores,
      when they can't be read from the database

  """

  use Mix.Task

  alias Arcana.MixHelpers

  @shortdoc "Generates a migration for embedding dimension changes"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dimensions: :integer, previous_dimensions: :integer]
      )

    # Start the app to access config
    Mix.Task.run("app.config")

    repo = MixHelpers.repo!()
    previous = resolve_previous_dimensions(repo, Keyword.get(opts, :previous_dimensions))

    dimensions =
      case Keyword.get(opts, :dimensions) do
        nil ->
          dims = MixHelpers.detect_dimensions!()
          Mix.shell().info("Detected embedding dimensions: #{dims}")
          dims

        dims ->
          dims = MixHelpers.validate_dimensions!(dims)
          Mix.shell().info("Using specified dimensions: #{dims}")
          dims
      end

    generate_migration(repo, dimensions, previous)
  end

  defp resolve_previous_dimensions(repo, nil) do
    case current_column_dimensions(repo) do
      nil ->
        Mix.shell().info(
          "Could not read the current arcana_chunks.embedding size; the generated " <>
            "down migration will raise. Pass --previous-dimensions to make it reversible."
        )

        nil

      dims ->
        Mix.shell().info("Current column dimensions (used for rollback): #{dims}")
        dims
    end
  end

  defp resolve_previous_dimensions(_repo, given),
    do: MixHelpers.validate_dimensions!(given, "--previous-dimensions")

  # pgvector stores the declared dimension straight in atttypmod, so
  # vector(384) reads back as 384.
  @current_dimensions_query """
  SELECT a.atttypmod
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = current_schema()
    AND c.relname = 'arcana_chunks'
    AND a.attname = 'embedding'
    AND NOT a.attisdropped
  """

  # Best effort: boots just the repo (not the host supervision tree, which
  # may load embedding models) to read the column's current size.
  defp current_column_dimensions(repo) do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    # A composing task may have already started the repo; leave that one
    # running and only tear down the one we booted.
    started =
      case repo.start_link(pool_size: 1, log: false) do
        {:ok, pid} -> pid
        {:error, {:already_started, _pid}} -> nil
      end

    try do
      case repo.query!(@current_dimensions_query) do
        %{rows: [[dims]]} when is_integer(dims) and dims > 0 -> dims
        _ -> nil
      end
    after
      if started do
        Process.unlink(started)
        Supervisor.stop(started)
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp generate_migration(repo, dimensions, previous) do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_update_embedding_dimensions.exs"

    # run/1 has already loaded the host app's config, so a repo that
    # configures its own :priv is visible here.
    migrations_dir = MixHelpers.migrations_path(repo)

    # Ensure the directory exists
    File.mkdir_p!(migrations_dir)

    path = Path.join(migrations_dir, filename)

    content = migration_content(dimensions, previous)

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

  @doc false
  def migration_content(dimensions, previous_dimensions \\ nil) do
    """
    defmodule Arcana.Repo.Migrations.UpdateEmbeddingDimensions do
      use Ecto.Migration

      def up do
        # Drop the existing HNSW index. The install migration creates it via
        # raw SQL as arcana_chunks_embedding_idx; also drop the Ecto-default
        # name defensively in case it was created under that name instead.
        execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"
        execute "DROP INDEX IF EXISTS arcana_chunks_embedding_index"

        # Alter the embedding column to new dimensions
        alter table(:arcana_chunks) do
          modify :embedding, :vector, size: #{dimensions}
        end

        # Recreate the HNSW index with the new dimensions. This must be raw
        # SQL because the operator class (vector_cosine_ops) cannot be
        # expressed through Ecto's index helper.
        execute \"\"\"
        CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
        USING hnsw (embedding vector_cosine_ops)
        \"\"\"
      end

    #{down_body(previous_dimensions)}
    end
    """
  end

  defp down_body(nil) do
    """
      def down do
        # Arcana could not determine the dimensions this column had before
        # the migration above, and guessing would truncate every embedding.
        # Fill in the previous size below, then delete this raise.
        raise "Set the previous vector size in this down migration before rolling back"

        # execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"
        # execute "DROP INDEX IF EXISTS arcana_chunks_embedding_index"
        #
        # alter table(:arcana_chunks) do
        #   modify :embedding, :vector, size: PREVIOUS_DIMENSIONS
        # end
        #
        # execute \"\"\"
        # CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
        # USING hnsw (embedding vector_cosine_ops)
        # \"\"\"
      end\
    """
  end

  defp down_body(previous) do
    """
      def down do
        execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"
        execute "DROP INDEX IF EXISTS arcana_chunks_embedding_index"

        # Restores the size the column had before this migration ran.
        alter table(:arcana_chunks) do
          modify :embedding, :vector, size: #{previous}
        end

        execute \"\"\"
        CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
        USING hnsw (embedding vector_cosine_ops)
        \"\"\"
      end\
    """
  end
end
