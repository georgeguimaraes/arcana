if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Arcana.Graph.Install do
    @shortdoc "Installs GraphRAG tables for Arcana"
    @moduledoc """
    Generates the migration for GraphRAG tables.

        $ mix arcana.graph.install

    This will create a migration for:
    - arcana_graph_entities - Named entities extracted from documents
    - arcana_graph_entity_mentions - Links entities to chunks where they appear
    - arcana_graph_relationships - Edges between entities
    - arcana_graph_communities - Community clusters with summaries

    GraphRAG is optional. Only run this if you want to use knowledge graph
    features for enhanced retrieval.

    ## Options

      * `--repo` - The repo to use (defaults to YourApp.Repo)

    ## Configuration

    After running the migration, enable GraphRAG in your config:

        config :arcana,
          graph: [
            enabled: true,
            community_levels: 5,
            resolution: 1.0
          ]

    Or enable per-call:

        Arcana.ingest(text, repo: MyApp.Repo, graph: true)
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :arcana,
        example: "mix arcana.graph.install",
        schema: [
          repo: :string
        ],
        defaults: [],
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

      igniter
      |> create_migration(repo_module)
      |> Igniter.add_notice("""

      GraphRAG migration created!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Enable GraphRAG in your config:

          config :arcana,
            graph: [
              enabled: true,
              community_levels: 5,
              resolution: 1.0
            ]

      3. Add the NER serving to your supervision tree (for entity extraction):

          children = [
            # ... existing children ...
            Arcana.Graph.NERServing
          ]

      4. Use GraphRAG during ingestion:

          Arcana.ingest(text, repo: #{inspect(repo_module)}, graph: true)

      See the GraphRAG guide for more details.
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
      filename = "#{timestamp}_create_arcana_graph_tables.exs"
      path = Path.join(migrations_path, filename)

      migration_content = """
      defmodule #{inspect(repo_module)}.Migrations.CreateArcanaGraphTables do
        use Ecto.Migration

        def up do
          create table(:arcana_graph_entities, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :name, :string, null: false
            add :type, :string, null: false
            add :description, :text
            add :embedding, :vector, size: 384
            add :metadata, :map, default: %{}
            add :chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :nilify_all)
            add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :delete_all)

            timestamps()
          end

          create unique_index(:arcana_graph_entities, [:name, :collection_id])
          create index(:arcana_graph_entities, [:collection_id])
          create index(:arcana_graph_entities, [:type])

          # HNSW index for entity embedding similarity search
          execute \"\"\"
          CREATE INDEX arcana_graph_entities_embedding_idx ON arcana_graph_entities
          USING hnsw (embedding vector_cosine_ops)
          WHERE embedding IS NOT NULL
          \"\"\"

          create table(:arcana_graph_entity_mentions, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :span_start, :integer
            add :span_end, :integer
            add :context, :text
            add :entity_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false
            add :chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :delete_all), null: false

            timestamps()
          end

          create index(:arcana_graph_entity_mentions, [:entity_id])
          create index(:arcana_graph_entity_mentions, [:chunk_id])

          create table(:arcana_graph_relationships, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :type, :string, null: false
            add :description, :text
            add :strength, :integer
            add :metadata, :map, default: %{}
            add :source_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false
            add :target_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false

            timestamps()
          end

          create index(:arcana_graph_relationships, [:source_id])
          create index(:arcana_graph_relationships, [:target_id])
          create index(:arcana_graph_relationships, [:type])

          create table(:arcana_graph_communities, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :level, :integer, null: false
            add :description, :text
            add :summary, :text
            add :entity_ids, {:array, :binary_id}, default: []
            add :dirty, :boolean, default: true
            add :change_count, :integer, default: 0
            add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :delete_all)

            timestamps()
          end

          create index(:arcana_graph_communities, [:collection_id])
          create index(:arcana_graph_communities, [:level])
        end

        def down do
          drop table(:arcana_graph_communities)
          drop table(:arcana_graph_relationships)
          drop table(:arcana_graph_entity_mentions)
          drop table(:arcana_graph_entities)
        end
      end
      """

      Igniter.create_new_file(igniter, path, migration_content)
    end
  end
else
  defmodule Mix.Tasks.Arcana.Graph.Install do
    @shortdoc "Generates GraphRAG migration for Arcana"
    @moduledoc """
    Generates the migration file for GraphRAG tables.

        $ mix arcana.graph.install

    This will create a migration for:
    - arcana_graph_entities - Named entities extracted from documents
    - arcana_graph_entity_mentions - Links entities to chunks where they appear
    - arcana_graph_relationships - Edges between entities
    - arcana_graph_communities - Community clusters with summaries

    GraphRAG is optional. Only run this if you want to use knowledge graph
    features for enhanced retrieval.

    ## Options

      * `--repo` - The repo to generate migrations for (defaults to YourApp.Repo)
    """

    use Mix.Task

    import Mix.Generator

    @migration_template """
    defmodule <%= @repo %>.Migrations.CreateArcanaGraphTables do
      use Ecto.Migration

      def up do
        create table(:arcana_graph_entities, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :name, :string, null: false
          add :type, :string, null: false
          add :description, :text
          add :embedding, :vector, size: 384
          add :metadata, :map, default: %{}
          add :chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :nilify_all)
          add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :delete_all)

          timestamps()
        end

        create unique_index(:arcana_graph_entities, [:name, :collection_id])
        create index(:arcana_graph_entities, [:collection_id])
        create index(:arcana_graph_entities, [:type])

        # HNSW index for entity embedding similarity search
        execute \"\"\"
        CREATE INDEX arcana_graph_entities_embedding_idx ON arcana_graph_entities
        USING hnsw (embedding vector_cosine_ops)
        WHERE embedding IS NOT NULL
        \"\"\"

        create table(:arcana_graph_entity_mentions, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :span_start, :integer
          add :span_end, :integer
          add :context, :text
          add :entity_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false
          add :chunk_id, references(:arcana_chunks, type: :binary_id, on_delete: :delete_all), null: false

          timestamps()
        end

        create index(:arcana_graph_entity_mentions, [:entity_id])
        create index(:arcana_graph_entity_mentions, [:chunk_id])

        create table(:arcana_graph_relationships, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :type, :string, null: false
          add :description, :text
          add :strength, :integer
          add :metadata, :map, default: %{}
          add :source_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false
          add :target_id, references(:arcana_graph_entities, type: :binary_id, on_delete: :delete_all), null: false

          timestamps()
        end

        create index(:arcana_graph_relationships, [:source_id])
        create index(:arcana_graph_relationships, [:target_id])
        create index(:arcana_graph_relationships, [:type])

        create table(:arcana_graph_communities, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :level, :integer, null: false
          add :description, :text
          add :summary, :text
          add :entity_ids, {:array, :binary_id}, default: []
          add :dirty, :boolean, default: true
          add :change_count, :integer, default: 0
          add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :delete_all)

          timestamps()
        end

        create index(:arcana_graph_communities, [:collection_id])
        create index(:arcana_graph_communities, [:level])
      end

      def down do
        drop table(:arcana_graph_communities)
        drop table(:arcana_graph_relationships)
        drop table(:arcana_graph_entity_mentions)
        drop table(:arcana_graph_entities)
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
      filename = "#{timestamp}_create_arcana_graph_tables.exs"
      path = Path.join(migrations_path, filename)

      content = EEx.eval_string(@migration_template, assigns: [repo: repo])

      create_file(path, content)

      Mix.shell().info("""

      GraphRAG migration created!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Enable GraphRAG in your config:

          config :arcana,
            graph: [
              enabled: true,
              community_levels: 5,
              resolution: 1.0
            ]

      3. Add the NER serving to your supervision tree (for entity extraction):

          children = [
            # ... existing children ...
            Arcana.Graph.NERServing
          ]

      4. Use GraphRAG during ingestion:

          Arcana.ingest(text, repo: MyApp.Repo, graph: true)

      See the GraphRAG guide for more details.
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
