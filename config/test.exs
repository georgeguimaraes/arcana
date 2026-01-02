import Config

# Mock embedder for tests - generates deterministic 384-dim embeddings based on text hash
# This is much faster than real embeddings and sufficient for testing RAG functionality
mock_embedder = fn text ->
  # Use hash of text to generate deterministic pseudo-random embeddings
  hash = :erlang.phash2(text, 1_000_000)
  :rand.seed(:exsss, {hash, hash * 2, hash * 3})

  embedding =
    for _ <- 1..384 do
      :rand.uniform() * 2 - 1
    end

  # Normalize to unit length
  norm = :math.sqrt(Enum.reduce(embedding, 0, fn x, acc -> acc + x * x end))
  normalized = Enum.map(embedding, fn x -> x / norm end)

  {:ok, normalized}
end

config :arcana,
  repo: Arcana.TestRepo,
  embedder: mock_embedder

config :arcana, Arcana.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5433")),
  database: "arcana_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
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
