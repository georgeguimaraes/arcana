defmodule Arcana.Graph.EntityMatcher do
  @moduledoc """
  Behaviour for matching query text to entities in the graph.

  Used by `Arcana.Search` and `Arcana.Ask` during graph-enhanced retrieval
  to find entities relevant to a query. The returned entity IDs are then
  used to fetch related chunks via the entity_mentions table.

  ## Built-in Implementations

    * `Arcana.Graph.EntityMatcher.Embedding` (default) - cosine similarity
      against entity description embeddings. Best for conceptual queries.
    * `Arcana.Graph.EntityMatcher.NER` - extract entity names from the query
      (via `Arcana.Graph.EntityExtractor`) and look them up by exact match.
      Best when queries name entities directly.

  ## Configuration

      # Global default (shortcut atom or module)
      config :arcana, graph: [entity_matcher: :ner]
      config :arcana, graph: [entity_matcher: Arcana.Graph.EntityMatcher.NER]

      # With options
      config :arcana, graph: [
        entity_matcher: {Arcana.Graph.EntityMatcher.Embedding, threshold: 0.5}
      ]

      # Per-call override
      Arcana.search(query, graph: true, entity_matcher: :ner)

  ## Custom implementations

      defmodule MyApp.SmartMatcher do
        @behaviour Arcana.Graph.EntityMatcher

        @impl true
        def match(query, collection_ids, opts) do
          # Your logic, returning {:ok, [entity_id]} or {:error, reason}
        end
      end

      config :arcana, graph: [entity_matcher: MyApp.SmartMatcher]

  """

  @doc """
  Matches a query to entity IDs in the graph.

  ## Parameters

    * `query` - the query text
    * `collection_ids` - optional list of collection UUIDs to scope the search,
      or `nil` for all collections
    * `opts` - keyword list including at least `:repo`. Implementations may
      accept their own options like `:threshold` and `:limit`.

  Returns `{:ok, entity_ids}` (possibly empty) or `{:error, reason}`.
  """
  @callback match(
              query :: String.t(),
              collection_ids :: [binary()] | nil,
              opts :: keyword()
            ) :: {:ok, [binary()]} | {:error, term()}
end
