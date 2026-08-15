defmodule Mix.Tasks.Arcana.Graph.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  # The installer's migration has to land where `mix ecto.migrate` reads
  # it: priv/ + the underscore of the repo's LAST module segment (or the
  # repo's configured :priv), never the underscore of the whole module
  # name. See Arcana.MigrationPath.
  defp created_migration_paths(igniter) do
    igniter.rewrite.sources
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(&1, "_create_arcana_graph_tables.exs"))
  end

  test "generates the migration under the repo's ecto migrations directory" do
    igniter =
      test_project()
      |> Igniter.compose_task("arcana.graph.install", ["--repo", "Test.Repo"])

    assert [path] = created_migration_paths(igniter)
    assert Path.dirname(path) == "priv/repo/migrations"
  end

  test "defaults to the app's repo" do
    igniter =
      test_project(app_name: :my_app)
      |> Igniter.compose_task("arcana.graph.install", [])

    assert [path] = created_migration_paths(igniter)
    assert Path.dirname(path) == "priv/repo/migrations"
  end
end
