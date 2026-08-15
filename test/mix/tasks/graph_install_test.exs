defmodule Mix.Tasks.Arcana.Graph.InstallTest do
  use ExUnit.Case, async: true

  import Arcana.ConfigCase
  import Igniter.Test

  defmodule FakeEmbedder do
    @behaviour Arcana.Embedder

    @impl true
    def embed(_text, _opts), do: {:ok, List.duplicate(0.0, 1024)}

    @impl true
    def embed_batch(texts, _opts),
      do: {:ok, Enum.map(texts, fn _ -> List.duplicate(0.0, 1024) end)}

    @impl true
    def dimensions(_opts), do: 1024
  end

  test "sizes entity embeddings from the configured embedder" do
    put_arcana_env(:embedder, FakeEmbedder)

    igniter =
      test_project()
      |> Igniter.compose_task("arcana.graph.install", [])

    assert migration_content(igniter) =~ ":embedding, :vector, size: 1024"
  end

  test "detects dimensions from the default (function) embedder config" do
    # The test config's fn embedder produces 384-dim vectors; detection
    # goes through Arcana.Embedder.Custom's probe.
    igniter =
      test_project()
      |> Igniter.compose_task("arcana.graph.install", [])

    assert migration_content(igniter) =~ ":embedding, :vector, size: 384"
  end

  test "--dimensions overrides detection" do
    put_arcana_env(:embedder, FakeEmbedder)

    igniter =
      test_project()
      |> Igniter.compose_task("arcana.graph.install", ["--dimensions", "512"])

    assert migration_content(igniter) =~ ":embedding, :vector, size: 512"
  end

  test "rejects a non-positive --dimensions instead of generating vector(0)" do
    for value <- ["0", "-5"] do
      assert_raise Mix.Error, ~r/--dimensions must be a positive integer/, fn ->
        test_project()
        |> Igniter.compose_task("arcana.graph.install", ["--dimensions", value])
      end
    end
  end

  # The migration has to land where `mix ecto.migrate` reads it: priv/ plus
  # the underscore of the repo's LAST module segment (or its configured
  # :priv), never the underscore of the whole module name. See
  # Arcana.MixHelpers.migrations_path/1.
  test "generates the migration under the repo's ecto migrations directory" do
    igniter =
      test_project()
      |> Igniter.compose_task("arcana.graph.install", ["--repo", "Test.Repo"])

    assert Path.dirname(migration_path(igniter)) == "priv/repo/migrations"
  end

  test "defaults to the app's repo" do
    igniter =
      test_project(app_name: :my_app)
      |> Igniter.compose_task("arcana.graph.install", [])

    assert Path.dirname(migration_path(igniter)) == "priv/repo/migrations"
  end

  defp migration_path(igniter) do
    paths =
      igniter.rewrite.sources
      |> Map.keys()
      |> Enum.filter(&String.ends_with?(&1, "_create_arcana_graph_tables.exs"))

    assert [path] = paths
    path
  end

  defp migration_content(igniter) do
    source =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.find(&String.contains?(&1.path, "create_arcana_graph_tables"))

    assert source, "expected a create_arcana_graph_tables migration to be created"
    Rewrite.Source.get(source, :content)
  end
end
