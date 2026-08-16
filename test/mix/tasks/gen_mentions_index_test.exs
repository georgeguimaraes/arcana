defmodule Mix.Tasks.Arcana.Graph.Gen.MentionsIndexTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Arcana.Graph.Gen.MentionsIndex

  # Two repos whose migration directory differs from the one the buggy
  # path builder produced: DefaultPrivRepo falls back to ecto's default
  # (priv/ + the underscore of the LAST module segment) and CustomPrivRepo
  # has an explicit :priv. Expectations are computed from
  # Mix.EctoSQL.source_repo_priv/1 — the same function `mix ecto.migrate`
  # resolves migrations through — not from a hand-written string.
  #
  # They hang off their own otp_app, not :arcana. Arcana.Config.repo!/1
  # scans the :arcana app env for per-repo entries and raises when it finds
  # more than one, so registering a second Ecto repo there would break
  # whichever async test happens to be scanning at the time.
  @otp_app :arcana_mentions_index_test

  defmodule DefaultPrivRepo do
    use Ecto.Repo, otp_app: :arcana_mentions_index_test, adapter: Ecto.Adapters.Postgres
  end

  defmodule CustomPrivRepo do
    use Ecto.Repo, otp_app: :arcana_mentions_index_test, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    Application.put_env(@otp_app, CustomPrivRepo, priv: "priv/mentions_index_custom_priv")

    on_exit(fn -> Application.delete_env(@otp_app, CustomPrivRepo) end)
    :ok
  end

  setup do
    on_exit(fn ->
      # Both the correct destination and the one the old path builder
      # picked, so a failing run leaves no stray directory behind.
      for repo <- [DefaultPrivRepo, CustomPrivRepo] do
        File.rm_rf!(ecto_migrations_path(repo))
        File.rm_rf!(legacy_migrations_path(repo))
      end
    end)

    :ok
  end

  defp ecto_migrations_path(repo) do
    repo
    |> Mix.EctoSQL.source_repo_priv()
    |> Path.relative_to_cwd()
    |> Path.join("migrations")
  end

  defp legacy_migrations_path(repo) do
    underscored =
      repo
      |> inspect()
      |> Macro.underscore()
      |> String.replace("/", "_")

    Path.join(["priv", underscored, "migrations"])
  end

  defp generated_migration(dir) do
    Path.wildcard(Path.join(dir, "*_add_arcana_graph_mentions_unique_index.exs"))
  end

  test "writes the migration where ecto.migrate reads it" do
    repo = inspect(DefaultPrivRepo)
    dir = ecto_migrations_path(DefaultPrivRepo)

    capture_io(fn -> MentionsIndex.run(["--repo", repo]) end)

    assert [path] = generated_migration(dir)
    assert File.read!(path) =~ "defmodule #{repo}.Migrations.AddArcanaGraphMentionsUniqueIndex"
    assert File.read!(path) =~ "create unique_index(:arcana_graph_entity_mentions"
  end

  test "honors a repo with a configured :priv" do
    repo = inspect(CustomPrivRepo)
    dir = ecto_migrations_path(CustomPrivRepo)

    assert dir == "priv/mentions_index_custom_priv/migrations"

    capture_io(fn -> MentionsIndex.run(["--repo", repo]) end)

    assert [_path] = generated_migration(dir)
  end
end
