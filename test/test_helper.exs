{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Start embeddings serving based on configured embedder
case Application.get_env(:arcana, :embedder) do
  {:local, opts} ->
    {:ok, _} = Arcana.Embedder.Local.start_link(opts)

  :local ->
    {:ok, _} = Arcana.Embedder.Local.start_link([])

  _ ->
    :ok
end

# Exclude slow tests by default:
# - :end_to_end - call real LLM APIs and cost money
# - :serving - require Arcana.Embeddings.Serving (not Embedder.Local)
# Run with: mix test --include end_to_end --include serving
#
# Limit concurrency to avoid DB connection timeouts during embeddings
ExUnit.start(exclude: [:end_to_end, :serving], max_cases: 4)
