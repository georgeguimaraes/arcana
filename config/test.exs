import Config

# Use EXLA for fast test embeddings
config :nx,
  default_backend: EXLA.Backend,
  default_defn_options: [compiler: EXLA]

# Use a smaller/faster model for tests (still 384 dims, but ~22M params vs ~33M)
config :arcana,
  repo: Arcana.TestRepo,
  embedder: {:local, model: "sentence-transformers/all-MiniLM-L6-v2"}

config :arcana, Arcana.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5433")),
  database: "arcana_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  ownership_timeout: 120_000,
  priv: "priv/test_repo",
  types: Arcana.PostgrexTypes

config :arcana, ArcanaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only",
  server: false,
  render_errors: [view: ArcanaWeb.ErrorView, accepts: ~w(html json), layout: false],
  live_view: [signing_salt: "test_live_view_salt"]

config :logger, level: :warning
