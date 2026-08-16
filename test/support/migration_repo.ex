defmodule Arcana.MigrationRepo do
  @moduledoc """
  A repo used only by the versioned-migration tests.

  Those tests run real DDL and read the catalog, which a sandbox
  transaction would roll back out from under them. They need their own
  database so they can create and drop Arcana's tables without disturbing
  the shared test database every other suite runs against.

  It hangs off its own otp_app rather than :arcana, because
  `Arcana.Config.repo!/1` scans :arcana for repo keys and raises when it
  finds more than one.
  """
  use Ecto.Repo,
    otp_app: :arcana_migration_test,
    adapter: Ecto.Adapters.Postgres
end
