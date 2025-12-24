defmodule Mix.Tasks.Arcana.Install do
  @shortdoc "Generates Arcana migrations for your application"
  @moduledoc """
  Generates the migration file needed for Arcana.

      $ mix arcana.install

  This will create a migration in your priv/repo/migrations directory
  that sets up the arcana_documents and arcana_chunks tables with
  pgvector support.

  ## Options

    * `--repo` - The repo to generate migrations for (defaults to YourApp.Repo)
  """

  use Mix.Task

  import Mix.Generator

  @migration_template """
  defmodule <%= @repo %>.Migrations.CreateArcanaTables do
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

      execute \"\"\"
      CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
      USING hnsw (embedding vector_cosine_ops)
      \"\"\"
    end

    def down do
      drop table(:arcana_chunks)
      drop table(:arcana_documents)
      execute "DROP EXTENSION IF EXISTS vector"
    end
  end
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string])

    repo = opts[:repo] || infer_repo()
    repo_underscore = Macro.underscore(repo) |> String.replace("/", "_")

    migrations_path = Path.join(["priv", repo_underscore, "migrations"])
    File.mkdir_p!(migrations_path)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_create_arcana_tables.exs"
    path = Path.join(migrations_path, filename)

    content = EEx.eval_string(@migration_template, assigns: [repo: repo])

    create_file(path, content)

    Mix.shell().info("""

    Arcana migration created!

    Next steps:
    1. Run the migration: mix ecto.migrate
    2. Add Arcana to your supervision tree:

        children = [
          MyApp.Repo,
          {Arcana, repo: MyApp.Repo}
        ]

    3. Configure pgvector types in your repo config:

        config :my_app, MyApp.Repo,
          types: MyApp.PostgrexTypes

    4. Create the types module:

        # lib/my_app/postgrex_types.ex
        Postgrex.Types.define(
          MyApp.PostgrexTypes,
          [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
          []
        )
    """)
  end

  defp infer_repo do
    case Mix.Project.config()[:app] do
      nil ->
        "MyApp.Repo"

      app ->
        app
        |> to_string()
        |> Macro.camelize()
        |> Kernel.<>(".Repo")
    end
  end
end
