{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Start embeddings serving based on configured embedder
embedder_model =
  case Application.get_env(:arcana, :embedder) do
    {:local, opts} -> Keyword.get(opts, :model, "BAAI/bge-small-en-v1.5")
    _ -> "BAAI/bge-small-en-v1.5"
  end

{:ok, _} = Arcana.Embedder.Local.start_link(model: embedder_model)
{:ok, _} = Arcana.Embeddings.Serving.start_link(model: embedder_model)

# Exclude end_to_end tests by default (call real LLM APIs and cost money)
# Run with: mix test --include end_to_end
#
# Limit concurrency to avoid DB connection timeouts during embeddings
ExUnit.start(exclude: [:end_to_end], max_cases: 4)
