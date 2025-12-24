defmodule Arcana.TestRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :arcana,
    adapter: Ecto.Adapters.Postgres
end
