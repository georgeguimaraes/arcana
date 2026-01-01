if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Arcana.Install do
    @shortdoc "Installs Arcana in your Phoenix application"
    @moduledoc """
    Installs Arcana in your Phoenix application.

        $ mix arcana.install

    This will:
    - Generate the migration for arcana_documents and arcana_chunks tables
    - Add the dashboard route to your Phoenix router
    - Create the Postgrex types module for pgvector
    - Configure your repo to use the types module

    ## Options

      * `--no-dashboard` - Skip adding the dashboard route
      * `--repo` - The repo to use (defaults to YourApp.Repo)
    """

    use Igniter.Mix.Task

    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Config

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :arcana,
        example: "mix arcana.install",
        schema: [
          dashboard: :boolean,
          repo: :string
        ],
        defaults: [dashboard: true],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      app_name = Igniter.Project.Application.app_name(igniter)
      app_module = app_name |> to_string() |> Macro.camelize()

      repo_module =
        if opts[:repo] do
          Module.concat([opts[:repo]])
        else
          Module.concat([app_module, "Repo"])
        end

      web_module = Module.concat([app_module <> "Web"])
      types_module = Module.concat([app_module, "PostgrexTypes"])

      igniter
      |> create_migration(repo_module)
      |> create_postgrex_types_module(types_module)
      |> configure_repo_types(app_name, repo_module, types_module)
      |> maybe_add_dashboard_route(opts[:dashboard], web_module)
      |> Igniter.add_notice("""

      Arcana installed successfully!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Add Arcana to your supervision tree:

          children = [
            #{inspect(repo_module)},
            Arcana.Embedder.Local,
            Arcana.TaskSupervisor
          ]

         For in-memory vector store (no PostgreSQL required), also add:

            {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}

         And configure: config :arcana, vector_store: :memory

      3. (Optional) Enable telemetry logging for observability:

          # In your application's start/2, before Supervisor.start_link
          Arcana.Telemetry.Logger.attach()

         See the Telemetry guide for Prometheus/LiveDashboard integration.

      4. Start using Arcana:

          {:ok, doc} = Arcana.ingest("Your content", repo: #{inspect(repo_module)})
          {:ok, results} = Arcana.search("query", repo: #{inspect(repo_module)})
      """)
    end

    defp create_migration(igniter, repo_module) do
      repo_underscore =
        repo_module
        |> Module.split()
        |> Enum.join(".")
        |> Macro.underscore()
        |> String.replace("/", "_")

      migrations_path = Path.join(["priv", repo_underscore, "migrations"])
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_create_arcana_tables.exs"
      path = Path.join(migrations_path, filename)

      migration_content = """
      defmodule #{inspect(repo_module)}.Migrations.CreateArcanaTables do
        use Ecto.Migration

        def up do
          execute "CREATE EXTENSION IF NOT EXISTS vector"

          create table(:arcana_collections, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :name, :string, null: false
            add :description, :text

            timestamps()
          end

          create unique_index(:arcana_collections, [:name])

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
            add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :nilify_all)

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
          create index(:arcana_documents, [:collection_id])

          execute \"\"\"
          CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
          USING hnsw (embedding vector_cosine_ops)
          \"\"\"

          # Evaluation tables
          create table(:arcana_evaluation_test_cases, primary_key: false) do
            add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
            add :question, :text, null: false
            add :source, :string, null: false, default: "synthetic"
            add :source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all)

            timestamps()
          end

          create table(:arcana_evaluation_test_case_chunks, primary_key: false) do
            add :test_case_id, references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all), null: false
            add :chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false
          end

          create unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id])

          create table(:arcana_evaluation_runs, primary_key: false) do
            add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
            add :status, :string, null: false, default: "running"
            add :metrics, :map, default: %{}
            add :results, :map, default: %{}
            add :config, :map, default: %{}
            add :test_case_count, :integer, default: 0

            timestamps()
          end

          create index(:arcana_evaluation_runs, [:inserted_at])
        end

        def down do
          drop table(:arcana_evaluation_runs)
          drop table(:arcana_evaluation_test_case_chunks)
          drop table(:arcana_evaluation_test_cases)
          drop table(:arcana_chunks)
          drop table(:arcana_documents)
          drop table(:arcana_collections)
          # Note: We don't drop the vector extension as it may be used by other tables
        end
      end
      """

      Igniter.create_new_file(igniter, path, migration_content)
    end

    defp create_postgrex_types_module(igniter, types_module) do
      types_content = """
      Postgrex.Types.define(
        #{inspect(types_module)},
        [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
        []
      )
      """

      path =
        types_module
        |> Module.split()
        |> Enum.map_join("/", &Macro.underscore/1)
        |> then(&"lib/#{&1}.ex")

      Igniter.create_new_file(igniter, path, types_content, on_exists: :skip)
    end

    defp configure_repo_types(igniter, app_name, repo_module, types_module) do
      Config.configure(
        igniter,
        "config.exs",
        app_name,
        [repo_module, :types],
        {:code, Sourceror.parse_string!(inspect(types_module))}
      )
    end

    defp maybe_add_dashboard_route(igniter, false, _web_module), do: igniter

    defp maybe_add_dashboard_route(igniter, _add_dashboard, web_module) do
      router_module = Module.concat([web_module, "Router"])

      # Add the arcana_dashboard macro call in a scope
      scope_code = """
        pipe_through [:browser]

        arcana_dashboard "/arcana"
      """

      igniter
      |> Phoenix.add_scope("/", scope_code, router: router_module)
      |> Igniter.add_notice("""

      IMPORTANT: Add this import to the top of your router (#{inspect(router_module)}):

          import ArcanaWeb.Router

      """)
    end
  end
else
  defmodule Mix.Tasks.Arcana.Install do
    @shortdoc "Generates Arcana migrations for your application"
    @moduledoc """
    Generates the migration file needed for Arcana.

        $ mix arcana.install

    This will create a migration in your priv/repo/migrations directory
    that sets up the arcana_documents and arcana_chunks tables with
    pgvector support.

    For automatic router and config setup, add `{:igniter, "~> 0.5"}` to
    your dependencies and re-run this task.

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

        create table(:arcana_collections, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :name, :string, null: false
          add :description, :text

          timestamps()
        end

        create unique_index(:arcana_collections, [:name])

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
          add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :nilify_all)

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
        create index(:arcana_documents, [:collection_id])

        execute \"\"\"
        CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
        USING hnsw (embedding vector_cosine_ops)
        \"\"\"

        # Evaluation tables
        create table(:arcana_evaluation_test_cases, primary_key: false) do
          add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
          add :question, :text, null: false
          add :source, :string, null: false, default: "synthetic"
          add :source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all)

          timestamps()
        end

        create table(:arcana_evaluation_test_case_chunks, primary_key: false) do
          add :test_case_id, references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all), null: false
          add :chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false
        end

        create unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id])

        create table(:arcana_evaluation_runs, primary_key: false) do
          add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
          add :status, :string, null: false, default: "running"
          add :metrics, :map, default: %{}
          add :results, :map, default: %{}
          add :config, :map, default: %{}
          add :test_case_count, :integer, default: 0

          timestamps()
        end

        create index(:arcana_evaluation_runs, [:inserted_at])
      end

      def down do
        drop table(:arcana_evaluation_runs)
        drop table(:arcana_evaluation_test_case_chunks)
        drop table(:arcana_evaluation_test_cases)
        drop table(:arcana_chunks)
        drop table(:arcana_documents)
        drop table(:arcana_collections)
        # Note: We don't drop the vector extension as it may be used by other tables
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
            Arcana.Embedder.Local,
            Arcana.TaskSupervisor
          ]

         For in-memory vector store (no PostgreSQL required), also add:

            {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}

         And configure: config :arcana, vector_store: :memory

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

      5. (Optional) Mount the dashboard in your router:

          # At the top of your router
          import ArcanaWeb.Router

          # In a scope with the :browser pipeline
          scope "/" do
            pipe_through [:browser]

            arcana_dashboard "/arcana"
          end

      6. (Optional) Enable telemetry logging for observability:

          # In your application's start/2, before Supervisor.start_link
          Arcana.Telemetry.Logger.attach()

         See the Telemetry guide for Prometheus/LiveDashboard integration.

      TIP: For automatic setup, add {:igniter, "~> 0.5"} to your deps
           and re-run mix arcana.install
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
end
