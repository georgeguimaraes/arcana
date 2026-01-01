defmodule Arcana.Agent.Searcher.Arcana do
  @moduledoc """
  Default searcher using Arcana's built-in pgvector search.

  Uses `Arcana.search/2` to perform semantic similarity search against
  the configured PostgreSQL database with pgvector.

  ## Usage

      # With Agent pipeline (this is the default)
      ctx
      |> Agent.search()
      |> Agent.answer()

      # Explicitly specifying the searcher
      ctx
      |> Agent.search(searcher: Arcana.Agent.Searcher.Arcana)
      |> Agent.answer()

  ## Options

  - `:repo` - The Ecto repo (required)
  - `:collection` - Collection name to search
  - `:limit` - Maximum chunks to return (default: 5)
  - `:threshold` - Minimum similarity threshold (default: 0.5)
  """

  @behaviour Arcana.Agent.Searcher

  @impl Arcana.Agent.Searcher
  def search(question, collection, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 5)
    threshold = Keyword.get(opts, :threshold, 0.5)

    Arcana.search(question,
      repo: repo,
      collection: collection,
      limit: limit,
      threshold: threshold
    )
  end
end
