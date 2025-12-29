{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the embedding serving for tests
{:ok, _} = Arcana.Embeddings.Serving.start_link([])

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude end-to-end tests by default (they call real LLM APIs and cost money)
# Run with: mix test --include end_to_end
ExUnit.start(exclude: [:end_to_end])
