defmodule Mix.Tasks.Arcana.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  @define_call """
  Postgrex.Types.define(
    Test.MyTypes,
    [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
    []
  )
  """

  test "generates the PostgrexTypes module on a clean project" do
    test_project()
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
  end

  test "skips generating when the app already calls Postgrex.Types.define" do
    test_project(files: %{"lib/test/my_types.ex" => @define_call})
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "Test.MyTypes"))
    |> assert_has_notice(&(&1 =~ "lib/test/my_types.ex"))
  end

  test "warns that a scanned types module may belong to a different repo" do
    postgis = """
    Postgrex.Types.define(
      Test.PostGISTypes,
      [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
      []
    )
    """

    test_project(files: %{"lib/test/postgis_types.ex" => postgis})
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_has_notice(&(&1 =~ "may belong to a different repo"))
    |> assert_has_notice(&(&1 =~ "config :test, Test.Repo, types: Test.PostGISTypes"))
  end

  test "resolves the __MODULE__.Types idiom instead of crashing" do
    code = """
    defmodule Test.MyRepo do
      use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres

      Postgrex.Types.define(__MODULE__.Types, [], [])
    end
    """

    test_project(files: %{"lib/test/my_repo.ex" => code})
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "Test.MyRepo.Types"))
  end

  test "falls back to an unnamed types module when the alias can't be resolved" do
    # __MODULE__ outside any defmodule has no name to resolve against.
    code = """
    Postgrex.Types.define(__MODULE__.Types, [], [])
    """

    test_project(files: %{"lib/test/weird_types.ex" => code})
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "Arcana found a types module defined by"))
  end

  test "skips generating when the repo config already sets :types" do
    test_project(
      files: %{
        "config/config.exs" => """
        import Config

        config :test, Test.Repo, types: Test.ExistingTypes
        """
      }
    )
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "already has a `:types` module configured"))
    |> assert_has_notice(&(&1 =~ "config/config.exs"))
  end

  test "the repo's own :types config wins over an unrelated define found in lib/" do
    igniter =
      test_project(
        files: %{
          "lib/test/postgis_types.ex" => @define_call,
          "config/config.exs" => """
          import Config

          config :test, Test.Repo, types: Test.ExistingTypes
          """
        }
      )
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_has_notice(igniter, &(&1 =~ "already has a `:types` module configured"))
    refute Enum.any?(igniter.notices, &(&1 =~ "Test.MyTypes"))
  end

  test "detects :types configured in an env file, not just config.exs" do
    test_project(
      files: %{
        "config/config.exs" => """
        import Config

        import_config "\#{config_env()}.exs"
        """,
        "config/runtime.exs" => """
        import Config

        config :test, Test.Repo, types: Test.ExistingTypes
        """
      }
    )
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "config/runtime.exs"))
  end

  test "keeps installing when a lib file mentioning the call has a syntax error" do
    broken = """
    defmodule Test.Broken do
      Postgrex.Types.define(
    end
    """

    test_project()
    |> add_file_after_setup("lib/test/broken.ex", broken)
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "could not parse these files"))
    |> assert_has_notice(&(&1 =~ "lib/test/broken.ex"))
  end

  test "never reads lib files that don't mention Postgrex.Types.define" do
    # A mid-refactor syntax error elsewhere in lib/ must not reach the parser.
    broken = """
    defmodule Test.Unrelated do
      def oops do
    end
    """

    igniter =
      test_project()
      |> add_file_after_setup("lib/test/unrelated.ex", broken)
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_creates(igniter, "lib/test/postgrex_types.ex")
    refute Enum.any?(igniter.notices, &(&1 =~ "could not parse these files"))
  end

  # Files passed to `test_project(files: ...)` are pulled into the rewrite by
  # its own `include_glob("**/*.*")`, which parses each one eagerly - so a
  # deliberately unparsable fixture blows up before the installer ever runs.
  # That glob is matched against absolute paths, and it silently matches
  # nothing when the checkout lives under a dot-directory (git worktrees under
  # `.claude/`, for one), which is why doing it the other way looks fine
  # locally and fails on CI. Adding the file afterwards keeps the fixture out
  # of that glob so the installer is the only thing that ever reads it.
  defp add_file_after_setup(igniter, path, content) do
    Igniter.assign(igniter, :test_files, Map.put(igniter.assigns.test_files, path, content))
  end
end
