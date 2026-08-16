defmodule Mix.Tasks.Arcana.Graph.Gen.SummaryFingerprint do
  @shortdoc "Generates the community summary fingerprint migration"
  @moduledoc """
  Generates a migration adding `summary_fingerprint` to communities.

      $ mix arcana.graph.gen.summary_fingerprint

  Community detection deletes and recreates every community row, so a
  summary is carried over to the membership it belonged to. Membership
  alone can't say whether that summary is still accurate: a summary is
  written from the community's relationships too, and ingesting another
  document adds relationships without moving anyone between communities.

  This column records what each summary was generated from, so a rebuild
  can tell an unchanged community from one whose graph moved on. New
  installs get it from `mix arcana.graph.install`; this task is the
  upgrade path for everyone else.

  Existing summaries have no fingerprint, so they refresh once on the next
  summarize run and settle afterwards.

  ## Options

    * `--repo` - The repo to generate the migration for (defaults to YourApp.Repo)

  """

  use Mix.Task

  import Mix.Generator

  @migration_template """
  defmodule <%= @repo %>.Migrations.AddArcanaCommunitySummaryFingerprint do
    use Ecto.Migration

    def up do
      alter table(:arcana_graph_communities) do
        add :summary_fingerprint, :string
      end
    end

    def down do
      alter table(:arcana_graph_communities) do
        remove :summary_fingerprint
      end
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
    filename = "#{timestamp}_add_arcana_community_summary_fingerprint.exs"
    path = Path.join(migrations_path, filename)

    content = EEx.eval_string(@migration_template, assigns: [repo: repo])

    create_file(path, content)

    Mix.shell().info("""

    Community summary fingerprint migration created!

    Run it with:

        mix ecto.migrate

    Summaries written before this column existed have no fingerprint, so
    they refresh once on the next summarize run and settle afterwards.
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
