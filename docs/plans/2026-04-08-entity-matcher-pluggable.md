# Pluggable Entity Matcher for Graph-Enhanced Search

## Overview

Make the entity matching strategy in graph-enhanced search a pluggable component, with three built-in implementations: embedding similarity (default), NER, and hybrid. Users can switch globally or per-call without forking the search pipeline.

## Motivation

The graph-enhanced search currently has two ways to find entities relevant to a query:

1. **NER**: extract entity names from the query text, look them up by exact match in the entities table
2. **Embedding similarity**: embed the query, find entities whose description embeddings are most similar via cosine distance

These are tradeoffs, not strict improvements:

- **NER wins** when queries name entities directly ("What did Liz decide about secrets in Starship UK?"). Synthetic test sets generated from chunks tend to do this, biasing eval toward NER.
- **Embedding wins** when queries describe entities semantically ("What kind of vehicle does the Trumpton police use?") or use concepts that don't appear verbatim in the corpus.
- **Embedding loses** when the query has semantic neighbors that pull in unrelated entities (e.g. "PC Potter" embedding-matches Harry Potter vehicles).

The current implementation buries this choice inside `Arcana.Search.enhance_with_graph_search/5` with a hardcoded "try embedding first, fall back to NER" pattern. Users can't switch strategies without forking.

We want:
- **Default to embedding** because it aligns with Microsoft GraphRAG's Local Search and works better on conceptual queries
- **NER as a one-line opt-in** for users with corpora where literal name matching is more reliable
- **Hybrid as another option** for the best of both
- **Custom implementations** following the same pluggable pattern as embedder/chunker/reranker

## Behaviour

```elixir
defmodule Arcana.Graph.EntityMatcher do
  @moduledoc """
  Behaviour for matching query text to entities in the graph.

  Implementations return entity IDs that are then used by the graph search
  to fetch related chunks via the entity_mentions table.
  """

  @callback match(
              query :: String.t(),
              collection_ids :: [binary()] | nil,
              opts :: keyword()
            ) :: {:ok, [entity_id :: binary()]} | {:error, term()}
end
```

The callback returns entity IDs (already in the database). The downstream graph search code uses those IDs the same way it does today.

## Built-in Implementations

### `Arcana.Graph.EntityMatcher.Embedding` (default)

Embeds the query and finds entities by cosine similarity against their description embeddings.

```elixir
def match(query, collection_ids, opts) do
  threshold = Keyword.get(opts, :threshold, 0.3)
  limit = Keyword.get(opts, :limit, 20)
  repo = Keyword.fetch!(opts, :repo)

  embedder = Arcana.Config.embedder()

  case Arcana.Embedder.embed(embedder, query, intent: :query) do
    {:ok, query_embedding} ->
      results =
        Arcana.Graph.GraphStore.search_by_embedding(query_embedding, collection_ids,
          repo: repo,
          limit: limit,
          threshold: threshold
        )

      {:ok, Enum.map(results, & &1.id)}

    error ->
      error
  end
end
```

Options:
- `:threshold` (default 0.3) — minimum cosine similarity
- `:limit` (default 20) — max entities returned

### `Arcana.Graph.EntityMatcher.NER`

Extracts entity names from the query using the configured entity extractor (NER or LLM), then looks them up by exact name match.

```elixir
def match(query, collection_ids, opts) do
  extractor = Arcana.Graph.resolve_entity_extractor(opts)
  repo = Keyword.fetch!(opts, :repo)

  case Arcana.Graph.EntityExtractor.extract(extractor, query) do
    {:ok, entities} when entities != [] ->
      entity_names = Enum.map(entities, & &1.name)
      ids = lookup_ids_by_name(entity_names, collection_ids, repo)
      {:ok, ids}

    _ ->
      {:ok, []}
  end
end
```

Options:
- `:entity_extractor` — override the configured extractor

### `Arcana.Graph.EntityMatcher.Hybrid`

Tries embedding first, falls back to NER when embedding returns no matches above the threshold.

```elixir
def match(query, collection_ids, opts) do
  case Embedding.match(query, collection_ids, opts) do
    {:ok, []} -> NER.match(query, collection_ids, opts)
    result -> result
  end
end
```

This is the strategy currently inlined in `enhance_with_graph_search`. Making it explicit lets users opt out of the fallback behavior if they don't want it.

## Configuration DX

Following the existing pluggable component pattern (embedder, chunker, reranker):

### Use the default

```elixir
config :arcana, graph: [enabled: true]
```

`Arcana.Graph.EntityMatcher.Embedding` is used.

### Switch globally with shortcuts

```elixir
config :arcana, graph: [
  enabled: true,
  entity_matcher: :ner          # or :embedding (default), :hybrid
]
```

The shortcut atoms expand via the existing `parse_pluggable/2` helper:

```elixir
def parse_entity_matcher_config(value) do
  parse_pluggable(value,
    name: "entity_matcher",
    shortcuts: %{
      embedding: Arcana.Graph.EntityMatcher.Embedding,
      ner: Arcana.Graph.EntityMatcher.NER,
      hybrid: Arcana.Graph.EntityMatcher.Hybrid
    }
  )
end
```

### Switch per-call

```elixir
Arcana.search("query", graph: true, entity_matcher: :ner)
Arcana.ask("question", graph: true, entity_matcher: :hybrid)
```

### Custom implementation

```elixir
defmodule MyApp.SmartMatcher do
  @behaviour Arcana.Graph.EntityMatcher

  @impl true
  def match(query, collection_ids, opts) do
    # ... your logic
    {:ok, entity_ids}
  end
end

config :arcana, graph: [entity_matcher: MyApp.SmartMatcher]

# or with options
config :arcana, graph: [
  entity_matcher: {MyApp.SmartMatcher, threshold: 0.7}
]
```

## Search Pipeline Changes

`Arcana.Search.enhance_with_graph_search/5` becomes:

```elixir
defp enhance_with_graph_search({:ok, vector_results}, query, collections, repo, opts) do
  limit = Keyword.get(opts, :limit, 10)
  graph_config = Arcana.Graph.config()
  rrf_k = graph_config[:rrf_k] || 60
  rrf_pool = graph_config[:rrf_pool_multiplier] || 2
  collection_ids = resolve_collection_ids(collections, repo)

  {matcher, matcher_opts} = resolve_entity_matcher(opts, graph_config)
  matcher_opts = Keyword.put(matcher_opts, :repo, repo)

  case matcher.match(query, collection_ids, matcher_opts) do
    {:ok, entity_ids} when entity_ids != [] ->
      :telemetry.span(
        [:arcana, :graph, :search],
        %{query: query, entity_count: length(entity_ids), matcher: matcher},
        fn ->
          graph_results = graph_search_by_entity_ids(entity_ids, repo)
          combined = rrf_combine(vector_results, graph_results, limit * rrf_pool, rrf_k)
          final_results = Enum.take(combined, limit)
          # ... existing telemetry/result wrapping
        end
      )

    _ ->
      format_search_results({:ok, vector_results}, limit)
  end
end

defp resolve_entity_matcher(opts, graph_config) do
  value =
    opts[:entity_matcher] ||
      graph_config[:entity_matcher] ||
      Arcana.Graph.EntityMatcher.Embedding

  Arcana.Config.parse_entity_matcher_config(value)
end
```

The two private helpers `find_entities_by_embedding/4` and `find_entities_by_ner/4` are removed from `Search` and replaced by the matcher dispatch.

## Files Changed

New:
- `lib/arcana/graph/entity_matcher.ex` — behaviour definition
- `lib/arcana/graph/entity_matcher/embedding.ex`
- `lib/arcana/graph/entity_matcher/ner.ex`
- `lib/arcana/graph/entity_matcher/hybrid.ex`
- `test/arcana/graph/entity_matcher_test.exs`

Modified:
- `lib/arcana/config.ex` — add `parse_entity_matcher_config/1`
- `lib/arcana/search.ex` — replace inlined matcher logic with dispatch
- `lib/arcana/graph.ex` — document `:entity_matcher` config option

## Backward Compatibility

The default changes from "hybrid (embedding then NER fallback)" to "embedding only". This is a behavior change for users relying on the implicit fallback.

Mitigations:
- Documented in CHANGELOG with the new `entity_matcher: :hybrid` opt-in for the old behavior
- The hybrid implementation is shipped as a built-in so users can switch with one line

The synthetic test set used in evaluation favors NER, so users running our eval suite will see lower numbers with the new default. This should be called out explicitly so they don't think it's a regression.

## Open Questions

1. Should `Hybrid` be the default instead of `Embedding`? It gets the best of both worlds at the cost of a fallback NER call.
2. Should we expose the matcher choice in `Arcana.config()` introspection?
3. Should the NER matcher be deprecated entirely if Hybrid is strictly better?
4. Should we add a `Multi` matcher that runs all matchers and unions the results, useful for "everything everywhere"?

## Out of Scope

- Generating new synthetic test sets that don't bias toward NER
- Changing the underlying entity extraction (NER vs LLM) — that's a separate concern
- Adding new matcher backends (e.g. fuzzy string matching, BM25 over entity names)
