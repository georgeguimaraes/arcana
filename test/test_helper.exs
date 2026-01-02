{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start embedding serving with tiny model for fast tests
test_model = Application.get_env(:arcana, :test_model, "hf-internal-testing/tiny-random-bert")
{:ok, _} = Arcana.Embeddings.Serving.start_link(model: test_model, tokenizer: "google-bert/bert-base-uncased")

# Start the endpoint for LiveView tests
{:ok, _} = ArcanaWeb.Endpoint.start_link()

# Exclude end-to-end tests by default (they call real LLM APIs and cost money)
# Run with: mix test --include end_to_end
ExUnit.start(exclude: [:end_to_end])
