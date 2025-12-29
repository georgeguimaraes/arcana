import Config

config :arcana, repo: Arcana.TestRepo

# Use a mock embedding function for tests (384 dimensions like bge-small-en-v1.5)
# Creates pseudo-embeddings where similar words produce similar vectors
config :arcana,
  embedder: fn text ->
    # Normalize and tokenize
    words =
      text
      |> String.downcase()
      |> String.replace(~r/[^\w\s]/, "")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.uniq()

    # Create a 384-dim embedding based on word hashes
    # Each word contributes to specific dimensions based on its hash
    base = List.duplicate(0.0, 384)

    embedding =
      Enum.reduce(words, base, fn word, acc ->
        # Use word hash to determine which dimensions to activate
        hash = :erlang.phash2(word)
        dim1 = rem(hash, 384)
        dim2 = rem(hash * 7, 384)
        dim3 = rem(hash * 13, 384)

        acc
        |> List.update_at(dim1, &(&1 + 0.5))
        |> List.update_at(dim2, &(&1 + 0.3))
        |> List.update_at(dim3, &(&1 + 0.2))
      end)

    # Normalize to unit length
    magnitude = :math.sqrt(Enum.reduce(embedding, 0.0, fn x, sum -> sum + x * x end))

    normalized =
      if magnitude > 0,
        do: Enum.map(embedding, &(&1 / magnitude)),
        else: embedding

    {:ok, normalized}
  end

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
