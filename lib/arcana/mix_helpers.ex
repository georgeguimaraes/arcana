defmodule Arcana.MixHelpers do
  @moduledoc false

  # Shared helpers for Arcana's mix tasks. Library functions raise regular
  # exceptions (ArgumentError, RuntimeError); these wrappers translate them
  # into `Mix.raise/1` so the CLI prints a single clean line instead of a
  # stacktrace.

  defguardp is_valid_dimensions(value) when is_integer(value) and value > 0

  @doc """
  Resolves the configured repo, converting `Arcana.Config.repo!/1`'s
  `ArgumentError` into a clean `Mix.raise`.

  `env` defaults to `nil`, which lets `Arcana.Config.repo!/1` read the app
  env itself. Pass an explicit keyword list to resolve against it.
  """
  def repo!(env \\ nil) do
    Arcana.Config.repo!(env)
  rescue
    e in ArgumentError -> Mix.raise(Exception.message(e))
  end

  @doc """
  Returns the migrations directory `mix ecto.migrate` reads for `repo`,
  relative to the cwd. Accepts a module or the `--repo` string a task was
  given.

  Ecto looks in `Path.join(Mix.EctoSQL.source_repo_priv(repo),
  "migrations")`, and `source_repo_priv/1` is the repo's configured
  `:priv` or `priv/` plus the underscore of the repo's LAST module
  segment — `MyApp.Repo` means `priv/repo`, not `priv/my_app_repo`.
  Generating into the underscore of the whole module name drops the file
  where ecto never looks: `mix ecto.migrate` reports nothing pending and
  the generated migration silently never runs.
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

  @doc """
  Detects embedding dimensions from the configured embedder.

  Loads the host application's config first, since the embedder is read
  from app env. Raises a `Mix.Error` with a `--dimensions` hint when the
  embedder can't be probed, or when it reports something that isn't a
  positive integer.
  """
  def detect_dimensions! do
    Mix.Task.run("app.config")
    {module, _opts} = embedder = Arcana.embedder()

    embedder
    |> Arcana.Embedder.dimensions()
    |> validate_detected_dimensions!(module)
  rescue
    e in Mix.Error ->
      reraise e, __STACKTRACE__

    e ->
      Mix.raise("""
      Could not detect embedding dimensions from the configured embedder: #{Exception.message(e)}

      Pass them explicitly with --dimensions, e.g.: --dimensions 1024
      """)
  end

  @doc """
  Validates a user-supplied vector dimension.

  Returns the value when it is a positive integer, raises a `Mix.Error`
  otherwise. Postgres rejects `vector(0)` and `vector(-1)`, so catching it
  here beats generating a migration that fails halfway through.
  """
  def validate_dimensions!(value, flag \\ "--dimensions")

  def validate_dimensions!(value, _flag) when is_valid_dimensions(value), do: value

  def validate_dimensions!(value, flag) do
    Mix.raise("#{flag} must be a positive integer, got: #{inspect(value)}")
  end

  # Same check as validate_dimensions!/2, but the value came from the
  # embedder rather than the command line, so the flag is the workaround
  # instead of the culprit.
  defp validate_detected_dimensions!(value, _module) when is_valid_dimensions(value), do: value

  defp validate_detected_dimensions!(value, module) do
    Mix.raise("""
    The configured embedder #{inspect(module)} reported invalid embedding dimensions: #{inspect(value)}

    Dimensions must be a positive integer. Fix the embedder's dimensions/1
    callback, or pass them explicitly with --dimensions, e.g.: --dimensions 1024
    """)
  end
end
