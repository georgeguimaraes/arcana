import Config

config :arcana, Arcana.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "arcana_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  priv: "priv/test_repo",
  types: Arcana.PostgrexTypes

config :logger, level: :warning
