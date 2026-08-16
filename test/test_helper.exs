# The versioned-migration tests run real DDL, so they use a database of
# their own. Configured here rather than in config/test.exs because Mix
# warns about config for an app that isn't a dependency.
#
# The connection is taken from TestRepo's rather than re-read from the same
# env vars, so pointing CI at a different Postgres moves both. Only the
# database and the pool differ: no sandbox, because these tests run DDL
# that a sandbox transaction would roll back under the assertions.
Application.put_env(
  :arcana_migration_test,
  Arcana.MigrationRepo,
  :arcana
  |> Application.get_env(Arcana.TestRepo)
  |> Keyword.take([:username, :password, :hostname, :port, :types])
  |> Keyword.merge(database: "arcana_migration_test", pool_size: 2)
)

{:ok, _} = Arcana.TestRepo.start_link()

# Vacuum the database before starting sandbox mode to clear dead tuples from prior runs
# This prevents performance degradation from accumulated dead tuples
Ecto.Adapters.SQL.query!(Arcana.TestRepo, "VACUUM ANALYZE", [])

Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Allow async tests to shadow :arcana config per-process instead of
# mutating global Application env (see Arcana.ConfigCase.put_arcana_env/2).
Arcana.ConfigCase.enable()

# Start the task supervisor used by LiveViews for async operations
# (evaluation, Ask page submissions, maintenance tasks). Without this,
# LiveView tests that trigger background tasks fail with "no process"
# on ArcanaWeb.TaskSupervisor.
{:ok, _} = Task.Supervisor.start_link(name: ArcanaWeb.TaskSupervisor)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude by default:
# - :end_to_end - calls real LLM APIs
# - :memory - hnswlib NIFs slow on CI
# - :serving - requires real Bumblebee model (slow)
# - :colbert - requires Stephen/ColBERT model (slow)
# - :pdf_support - requires poppler (pdftotext) installed
# Run with: mix test --include serving --include memory --include end_to_end --include colbert --include pdf_support
ExUnit.start(exclude: [:memory, :end_to_end, :serving, :colbert, :pdf_support])
