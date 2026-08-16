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

    Entity embedding dimensions are detected from the configured embedder
    (via `Arcana.Embedder.dimensions/1`), so the generated table matches
    your vectors. Use `--dimensions` to override.

    ## Options

      * `--repo` - The repo to use (defaults to YourApp.Repo)
      * `--dimensions` - Override auto-detected embedding dimensions

    ## Configuration

    After running the migration, enable GraphRAG in your config:

        config :arcana,
          graph: [
            enabled: true,
            community_levels: 1,
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
          repo: :string,
          dimensions: :integer
        ],
        defaults: [],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      # Igniter's own run/1 wrapper runs "compile", not "app.config", so
      # config/runtime.exs is still unread when we get here. Without this
      # the repo's `:priv` is only visible when detect_dimensions! happens
      # to load it, which --dimensions skips.
      Mix.Task.run("app.config")

      opts = igniter.args.options
      app_name = Igniter.Project.Application.app_name(igniter)
      app_module = app_name |> to_string() |> Macro.camelize()

      repo_module =
        if opts[:repo] do
          Module.concat([opts[:repo]])
        else
          Module.concat([app_module, "Repo"])
        end

      dimensions = resolve_dimensions(opts[:dimensions])

      igniter
      |> create_migration(repo_module, dimensions)
      |> Igniter.add_notice("""

      GraphRAG migration created!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Enable GraphRAG in your config:

          config :arcana,
            graph: [
              enabled: true,
              community_levels: 1,
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

    defp resolve_dimensions(nil), do: Arcana.MixHelpers.detect_dimensions!()
    defp resolve_dimensions(given), do: Arcana.MixHelpers.validate_dimensions!(given)

    defp create_migration(igniter, repo_module, dimensions) do
      migrations_path = Arcana.MixHelpers.migrations_path(repo_module)
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_add_arcana_graph.exs"
      path = Path.join(migrations_path, filename)

      Igniter.create_new_file(igniter, path, migration_contents(repo_module, dimensions))
    end

    # Delegates rather than spelling out DDL: Arcana owns one definition of
    # the graph schema and its version history. The detected dimensions are
    # passed through because the entity embedding column depends on them.
    defp migration_contents(repo_module, dimensions) do
      """
      defmodule #{inspect(repo_module)}.Migrations.AddArcanaGraph do
        use Ecto.Migration

        def up, do: Arcana.Graph.Migration.up(dimensions: #{dimensions})

        def down, do: Arcana.Graph.Migration.down()
      end
      """
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

    Entity embedding dimensions are detected from the configured embedder
    (via `Arcana.Embedder.dimensions/1`), so the generated table matches
    your vectors. Use `--dimensions` to override.

    ## Options

      * `--repo` - The repo to generate migrations for (defaults to YourApp.Repo)
      * `--dimensions` - Override auto-detected embedding dimensions
    """

    use Mix.Task

    import Mix.Generator

    @impl Mix.Task
    def run(args) do
      {opts, _, _} = OptionParser.parse(args, strict: [repo: :string, dimensions: :integer])

      # Load the host app's config so the repo's `:priv`, if it has one, is
      # visible to Arcana.MixHelpers.migrations_path/1.
      Mix.Task.run("app.config")

      repo = opts[:repo] || infer_repo()
      dimensions = resolve_dimensions(opts[:dimensions])

      migrations_path = Arcana.MixHelpers.migrations_path(repo)
      File.mkdir_p!(migrations_path)

      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_add_arcana_graph.exs"
      path = Path.join(migrations_path, filename)

      content =
        migration_contents(Module.concat([repo]), dimensions)

      create_file(path, content)

      Mix.shell().info("""

      GraphRAG migration created!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Enable GraphRAG in your config:

          config :arcana,
            graph: [
              enabled: true,
              community_levels: 1,
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

    defp resolve_dimensions(nil), do: Arcana.MixHelpers.detect_dimensions!()
    defp resolve_dimensions(given), do: Arcana.MixHelpers.validate_dimensions!(given)

    defp migration_contents(repo_module, dimensions) do
      """
      defmodule #{inspect(repo_module)}.Migrations.AddArcanaGraph do
        use Ecto.Migration

        def up, do: Arcana.Graph.Migration.up(dimensions: #{dimensions})

        def down, do: Arcana.Graph.Migration.down()
      end
      """
    end
  end
end
