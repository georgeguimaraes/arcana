{:ok, _} = Arcana.TestRepo.start_link()
Ecto.Adapters.SQL.Sandbox.mode(Arcana.TestRepo, :manual)

# Start the embedding serving for tests
{:ok, _} = Arcana.Embeddings.Serving.start_link([])

ExUnit.start()
