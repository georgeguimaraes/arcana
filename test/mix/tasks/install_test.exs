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

  test "still configures the repo when the app defines an unrelated types module" do
    igniter =
      test_project(files: %{"lib/test/my_types.ex" => @define_call})
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    # The scanned module says nothing about which repo it serves, so Test.Repo
    # gets its own - skipping would leave it without pgvector registered.
    assert_creates(igniter, "lib/test/postgrex_types.ex")

    assert_has_patch(
      igniter,
      "config/config.exs",
      "|config :test, Test.Repo, types: Test.PostgrexTypes"
    )

    assert_has_notice(igniter, &(&1 =~ "Test.MyTypes"))
    assert_has_notice(igniter, &(&1 =~ "lib/test/my_types.ex"))
    assert_unchanged(igniter, "lib/test/my_types.ex")
  end

  test "picks a name that can't collide with the module it found" do
    collides = String.replace(@define_call, "Test.MyTypes", "Test.PostgrexTypes")

    igniter =
      test_project(files: %{"lib/test/postgrex_types.ex" => collides})
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_creates(igniter, "lib/test/repo/postgrex_types.ex")

    assert_has_patch(
      igniter,
      "config/config.exs",
      "|config :test, Test.Repo, types: Test.Repo.PostgrexTypes"
    )

    assert_unchanged(igniter, "lib/test/postgrex_types.ex")
  end

  test "doesn't claim a lib file that's already there for something else" do
    unrelated = """
    defmodule Test.PostgrexTypes do
      def whatever, do: :ok
    end
    """

    igniter =
      test_project(files: %{"lib/test/postgrex_types.ex" => unrelated})
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_creates(igniter, "lib/test/repo/postgrex_types.ex")

    assert_has_patch(
      igniter,
      "config/config.exs",
      "|config :test, Test.Repo, types: Test.Repo.PostgrexTypes"
    )

    assert_unchanged(igniter, "lib/test/postgrex_types.ex")
  end

  test "finds a candidate module defined outside its conventional path" do
    # Nothing makes an app put Test.PostgrexTypes in lib/test/postgrex_types.ex,
    # and generating a second definition of it would be a duplicate module.
    elsewhere = """
    defmodule Test.PostgrexTypes do
      def whatever, do: :ok
    end
    """

    igniter =
      test_project(files: %{"lib/test/db/types.ex" => elsewhere})
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_creates(igniter, "lib/test/repo/postgrex_types.ex")

    assert_has_patch(
      igniter,
      "config/config.exs",
      "|config :test, Test.Repo, types: Test.Repo.PostgrexTypes"
    )

    assert_unchanged(igniter, "lib/test/db/types.ex")
  end

  test "stops with an actionable error when every candidate name is taken" do
    occupied = fn module ->
      """
      defmodule #{module} do
        def whatever, do: :ok
      end
      """
    end

    project =
      test_project(
        files: %{
          "lib/test/postgrex_types.ex" => occupied.("Test.PostgrexTypes"),
          "lib/test/repo/postgrex_types.ex" => occupied.("Test.Repo.PostgrexTypes"),
          "lib/test/repo/arcana_postgrex_types.ex" => occupied.("Test.Repo.ArcanaPostgrexTypes")
        }
      )

    # Picking an occupied name silently would point the repo config at a module
    # that has no pgvector extension in it, so this has to stop the install.
    error =
      assert_raise Mix.Error, fn ->
        Igniter.compose_task(project, "arcana.install", ["--no-dashboard"])
      end

    assert error.message =~ "Test.Repo.ArcanaPostgrexTypes"
    assert error.message =~ "lib/test/repo/arcana_postgrex_types.ex"
    assert error.message =~ "Pgvector.Extensions.Vector"
  end

  test "leaves another repo's types module alone and generates one for ours" do
    postgis = """
    Postgrex.Types.define(
      Test.PostGISTypes,
      [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
      []
    )
    """

    igniter =
      test_project(files: %{"lib/test/postgis_types.ex" => postgis})
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_creates(igniter, "lib/test/postgrex_types.ex")
    assert_unchanged(igniter, "lib/test/postgis_types.ex")
    assert_has_notice(igniter, &(&1 =~ "generated Test.PostgrexTypes for Test.Repo"))
    assert_has_notice(igniter, &(&1 =~ "config :test, Test.Repo, types: Test.PostGISTypes"))
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
    |> assert_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "Test.MyRepo.Types"))
  end

  test "falls back to an unnamed types module when the alias can't be resolved" do
    # __MODULE__ outside any defmodule has no name to resolve against.
    code = """
    Postgrex.Types.define(__MODULE__.Types, [], [])
    """

    test_project(files: %{"lib/test/weird_types.ex" => code})
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
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
    |> assert_has_notice(&(&1 =~ "Test.ExistingTypes"))
  end

  test "names the configured module in the skip notice, not a placeholder" do
    igniter =
      test_project(
        files: %{
          "config/config.exs" => """
          import Config

          config :test, Test.Repo, types: Test.ExistingTypes
          """
        }
      )
      |> Igniter.compose_task("arcana.install", ["--no-dashboard"])

    assert_has_notice(igniter, &(&1 =~ "Postgrex.Types.define(\n      Test.ExistingTypes,"))
    refute Enum.any?(igniter.notices, &(&1 =~ "YourApp.PostgrexTypes"))
  end

  test "detects :types in a config file outside the usual env set" do
    test_project(
      files: %{
        "config/config.exs" => """
        import Config

        import_config "local.exs"
        """,
        "config/local.exs" => """
        import Config

        config :test, Test.Repo, types: Test.LocalTypes
        """
      }
    )
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "config/local.exs"))
    |> assert_has_notice(&(&1 =~ "Test.LocalTypes"))
  end

  test "keeps installing when a config file can't be parsed" do
    test_project()
    |> add_file_after_setup("config/broken.exs", "import Config\n\nconfig :test, [\n")
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "could not parse these files"))
    |> assert_has_notice(&(&1 =~ "config/broken.exs"))
  end

  test "keeps installing when a lib file at a candidate's path can't be parsed" do
    # Looking for a module definition parses the file it looks at, so a broken
    # one used to abort the install with a Sourceror error.
    test_project()
    |> add_file_after_setup(
      "lib/test/postgrex_types.ex",
      "defmodule Test.Broken do\n  def a(\nend\n"
    )
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/repo/postgrex_types.ex")
  end

  test "says which places detection looked at when it generates a module" do
    test_project()
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "config imported from elsewhere or built at runtime"))
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
    |> assert_has_notice(&(&1 =~ "Test.ExistingTypes"))
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
