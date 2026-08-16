defmodule Mix.Tasks.Arcana.Graph.Gen.MentionsIndex do
  @shortdoc "Generates the entity mention unique index migration"
  @moduledoc """
  Generates a migration adding the unique index on entity mentions.

      $ mix arcana.graph.gen.mentions_index

  Installs that ran `mix arcana.graph.install` before this index existed
  keep accumulating one mention row per (entity, chunk) per ingest, and
  the `on_conflict: :nothing` the graph store writes with is a silent
  no-op without the index. New installs get it from
  `mix arcana.graph.install`; this task is the upgrade path for everyone
  else.

  The generated migration deletes existing duplicates (keeping the oldest
  row per pair) before creating the index.

  ## Options

    * `--repo` - The repo to generate the migration for (defaults to YourApp.Repo)

  """

  use Mix.Task

  import Mix.Generator

  @migration_template """
  defmodule <%= @repo %>.Migrations.AddArcanaGraphMentionsUniqueIndex do
    use Ecto.Migration

    def up do
      # Remove duplicate mentions before adding the unique index, keeping
      # the oldest row per (entity_id, chunk_id) pair. Order by inserted_at:
      # ctid is a physical location, not an insertion order, so a vacuumed
      # or updated table can hand the lowest ctid to the newest row.
      # ctid only breaks ties within the same timestamp.
      execute(\"\"\"
      DELETE FROM arcana_graph_entity_mentions m
      USING arcana_graph_entity_mentions kept
      WHERE m.entity_id = kept.entity_id
        AND m.chunk_id = kept.chunk_id
        AND (m.inserted_at > kept.inserted_at
             OR (m.inserted_at = kept.inserted_at AND m.ctid > kept.ctid))
      \"\"\")

      create unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id])
    end

    def down do
      drop unique_index(:arcana_graph_entity_mentions, [:entity_id, :chunk_id])
    end
  end
  """

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [repo: :string])

    # Load the host app's config so the repo's `:priv`, if it has one, is
    # visible to Arcana.MixHelpers.migrations_path/1.
    Mix.Task.run("app.config")

    repo = opts[:repo] || infer_repo()

    migrations_path = Arcana.MixHelpers.migrations_path(repo)
    File.mkdir_p!(migrations_path)

    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
    filename = "#{timestamp}_add_arcana_graph_mentions_unique_index.exs"
    path = Path.join(migrations_path, filename)

    content = EEx.eval_string(@migration_template, assigns: [repo: repo])

    create_file(path, content)

    Mix.shell().info("""

    Entity mention unique index migration created!

    Run it with:

        mix ecto.migrate

    Duplicate mentions accumulated so far are deleted by the migration,
    keeping the oldest row of each (entity, chunk) pair.
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
