{:ok, _} = Arcana.TestRepo.start_link()

# Vacuum the database before starting sandbox mode to clear dead tuples from prior runs
# This prevents performance degradation from accumulated dead tuples
Ecto.Adapters.SQL.query!(Arcana.TestRepo, "VACUUM ANALYZE", [])

Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude by default:
# - :end_to_end - calls real LLM APIs
# - :memory - hnswlib NIFs slow on CI
# - :serving - requires real Bumblebee model (slow)
# - :colbert - requires Stephen/ColBERT model (slow)
# Run with: mix test --include serving --include memory --include end_to_end --include colbert
ExUnit.start(exclude: [:memory, :end_to_end, :serving, :colbert])
