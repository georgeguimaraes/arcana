defmodule Mix.Tasks.Arcana.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Rewrite.Source.Ex

  test "generates the PostgrexTypes module on a clean project" do
    test_project()
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> assert_creates("lib/test/postgrex_types.ex")
  end

  test "skips generating when the app already calls Postgrex.Types.define" do
    code = """
    Postgrex.Types.define(
      Test.MyTypes,
      [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
      []
    )
    """

    # Injected straight into the rewrite: igniter's test mode can't match
    # test_project(files:) fixtures against lib/** globs (relative glob vs
    # absolute expanded path), so include_glob would never surface the file.
    igniter = test_project()
    source = Ex.from_string(code, path: "lib/test/my_types.ex")
    igniter = %{igniter | rewrite: Rewrite.put!(igniter.rewrite, source)}

    igniter
    |> Igniter.compose_task("arcana.install", ["--no-dashboard"])
    |> refute_creates("lib/test/postgrex_types.ex")
    |> assert_has_notice(&(&1 =~ "Test.MyTypes"))
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
    |> assert_has_notice(&(&1 =~ "existing Postgrex types module was detected"))
  end
end
