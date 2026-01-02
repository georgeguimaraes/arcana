{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude slow tests by default:
# - :end_to_end - call real LLM APIs and cost money
# - :serving - require real Nx.Serving (slow model loading)
# Run with: mix test --include end_to_end --include serving
ExUnit.start(exclude: [:end_to_end, :serving])
