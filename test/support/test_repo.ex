defmodule Arcana.TestRepo do
  use Ecto.Repo,
    otp_app: :arcana,
    adapter: Ecto.Adapters.Postgres
end
