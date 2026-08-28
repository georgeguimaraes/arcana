defmodule Arcana.Searcher.Arcana do
  @moduledoc """
  Default searcher using Arcana's built-in pgvector search.

  Uses `Arcana.search/2` to perform semantic similarity search against
  the configured PostgreSQL database with pgvector.

  ## Usage

      # With Arcana.Pipeline (this is the default)
      ctx
      |> Pipeline.search()
      |> Pipeline.answer()

      # Explicitly specifying the searcher
      ctx
      |> Pipeline.search(searcher: Arcana.Searcher.Arcana)
      |> Pipeline.answer()

  ## Options

  - `:repo` - The Ecto repo (required)
  - `:collection` - A collection name, or `:all`
  - `:limit` - Maximum chunks to return (default: 5)
  - `:threshold` - Minimum similarity threshold (default: 0.5)
  """

  @behaviour Arcana.Searcher

  @impl Arcana.Searcher
  def search(question, collection, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 5)
    threshold = Keyword.get(opts, :threshold, 0.5)

    opts
    |> Keyword.drop([:collections])
    |> Keyword.merge(
      repo: repo,
      collection: collection,
      limit: limit,
      threshold: threshold
    )
    |> then(&Arcana.search(question, &1))
  end
end
