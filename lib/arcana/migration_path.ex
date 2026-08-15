defmodule Arcana.MigrationPath do
  @moduledoc false

  # Resolves the directory `mix ecto.migrate` actually reads migrations
  # from, for the generator tasks that write them.
  #
  # Ecto looks in `Path.join(Mix.EctoSQL.source_repo_priv(repo),
  # "migrations")`, and `source_repo_priv/1` is the repo's configured
  # `:priv` or `priv/` plus the underscore of the repo's LAST module
  # segment — `MyApp.Repo` means `priv/repo`, not `priv/my_app_repo`.
  # Generating into the underscore of the whole module name drops the
  # file where ecto never looks: `mix ecto.migrate` reports nothing
  # pending and the generated migration silently never runs.

  @doc """
  Returns the migrations directory for `repo`, relative to the cwd.

  Accepts a module or the `--repo` string a task was given.
  """
  def migrations_path(repo) when is_binary(repo) do
    repo
    |> String.split(".")
    |> Module.concat()
    |> migrations_path()
  end

  def migrations_path(repo) when is_atom(repo) do
    Path.join(repo_priv(repo), "migrations")
  end

  # The repo module is the authority on its own `:priv` whenever it can be
  # loaded. It can't be during an installer run in a project that hasn't
  # compiled yet, so fall back to ecto's own default rule rather than
  # failing the generator.
  defp repo_priv(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo
      |> Mix.EctoSQL.source_repo_priv()
      |> Path.relative_to_cwd()
    else
      default_priv(repo)
    end
  rescue
    _ -> default_priv(repo)
  end

  defp default_priv(repo) do
    Path.join("priv", repo |> Module.split() |> List.last() |> Macro.underscore())
  end
end
