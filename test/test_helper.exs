{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude end_to_end tests (call real LLM APIs) and memory tests (hnswlib NIFs slow on CI)
# Run with: mix test --include end_to_end --include memory
ExUnit.start(exclude: [:memory, :end_to_end])
