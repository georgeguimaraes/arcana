# GraphRAG

Build knowledge graphs from documents for enhanced retrieval with entity extraction, relationship mapping, and community detection.

## Overview

GraphRAG enhances traditional vector search by building a knowledge graph from your documents. This allows:

- **Entity-based retrieval** - Find chunks by following entity relationships
- **Community summaries** - High-level context about clusters of related entities
- **Fusion search** - Combine vector and graph results with Reciprocal Rank Fusion

## Installation

GraphRAG requires additional database tables. Install them separately:

```bash
mix arcana.graph.install
mix ecto.migrate
```

This creates tables for entities, relationships, entity mentions, and communities.

Add the NER serving to your supervision tree for entity extraction:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  Arcana.Embedder.Local,
  Arcana.Graph.NERServing  # Add this for GraphRAG
]
```

## Configuration

GraphRAG is disabled by default. Enable it globally:

```elixir
# config/config.exs
config :arcana,
  graph: [
    enabled: true,
    community_levels: 5,
    resolution: 1.0
  ]
```

Or enable per-call:

```elixir
Arcana.ingest(text, repo: MyApp.Repo, graph: true)
Arcana.search(query, repo: MyApp.Repo, graph: true)
```

## Components

GraphRAG uses three pluggable behaviours:

| Component | Default | Purpose |
|-----------|---------|---------|
| EntityExtractor | `Arcana.Graph.EntityExtractor.NER` | Extract entities from text |
| RelationshipExtractor | `Arcana.Graph.RelationshipExtractor.LLM` | Find relationships between entities |
| CommunityDetector | `Arcana.Graph.CommunityDetector.Leiden` | Detect entity communities |

## Building a Graph

### Basic Usage

```elixir
alias Arcana.Graph

# Build graph from chunks
{:ok, graph_data} = Graph.build(chunks,
  entity_extractor: {Graph.EntityExtractor.NER, []},
  relationship_extractor: {Graph.RelationshipExtractor.LLM, llm: &MyApp.llm/3}
)

# Convert to queryable format
graph = Graph.to_query_graph(graph_data, chunks)
```

### Entity Extraction

The default NER extractor uses Bumblebee for local entity recognition:

```elixir
# Default NER extractor
extractor = {Arcana.Graph.EntityExtractor.NER, []}
{:ok, entities} = Arcana.Graph.EntityExtractor.extract(extractor, text)

# Returns entities like:
# [
#   %{name: "Sam Altman", type: :person},
#   %{name: "OpenAI", type: :organization}
# ]
```

### Relationship Extraction

The LLM extractor uses an LLM to identify semantic relationships:

```elixir
# LLM-based relationship extraction
extractor = {Arcana.Graph.RelationshipExtractor.LLM, llm: &MyApp.llm/3}
{:ok, relationships} = Arcana.Graph.RelationshipExtractor.extract(extractor, text, entities)

# Returns relationships like:
# [
#   %{source: "Sam Altman", target: "OpenAI", type: "LEADS", strength: 9}
# ]
```

### Community Detection

The Leiden algorithm detects clusters of related entities:

```elixir
# Leiden community detection
detector = {Arcana.Graph.CommunityDetector.Leiden, resolution: 1.0}
{:ok, communities} = Arcana.Graph.CommunityDetector.detect(detector, entities, relationships)

# Returns communities with hierarchy:
# [
#   %{level: 0, entity_ids: ["entity1", "entity2"]},
#   %{level: 1, entity_ids: ["entity1", "entity2", "entity3"]}
# ]
```

## Querying the Graph

### Find Entities

```elixir
# Find entities by name
entities = Graph.find_entities(graph, "OpenAI")

# With fuzzy matching
entities = Graph.find_entities(graph, "Open AI", fuzzy: true)
```

### Traverse Relationships

```elixir
# Get connected entities
connected = Graph.traverse(graph, entity_id, depth: 2)
```

### Graph Search

```elixir
# Search graph for relevant chunks
entities = [%{name: "OpenAI", type: :organization}]
results = Graph.search(graph, entities, depth: 2)
```

## Fusion Search

Combine vector and graph search with Reciprocal Rank Fusion:

```elixir
# Run vector search
{:ok, vector_results} = Arcana.search(query, repo: MyApp.Repo)

# Extract entities from query
{:ok, entities} = Arcana.Graph.EntityExtractor.NER.extract(query, [])

# Combine with graph search
results = Graph.fusion_search(graph, entities, vector_results,
  depth: 2,
  limit: 10,
  k: 60  # RRF constant
)
```

## Community Summaries

Get high-level context about entity clusters:

```elixir
# Get all summaries at a specific level
summaries = Graph.community_summaries(graph, level: 0)

# Get summaries containing a specific entity
summaries = Graph.community_summaries(graph, entity_id: "entity123")
```

## Custom Implementations

All components support custom implementations via behaviours.

### Custom Entity Extractor

```elixir
defmodule MyApp.SpacyExtractor do
  @behaviour Arcana.Graph.EntityExtractor

  @impl true
  def extract(text, opts) do
    endpoint = Keyword.get(opts, :endpoint)
    # Call your spaCy API...
    {:ok, entities}
  end
end

# Configure globally
config :arcana, :graph,
  entity_extractor: {MyApp.SpacyExtractor, endpoint: "http://localhost:5000"}
```

### Custom Relationship Extractor

```elixir
defmodule MyApp.PatternExtractor do
  @behaviour Arcana.Graph.RelationshipExtractor

  @impl true
  def extract(text, entities, opts) do
    patterns = Keyword.get(opts, :patterns, [])
    # Pattern-based extraction...
    {:ok, relationships}
  end
end

# Configure globally
config :arcana, :graph,
  relationship_extractor: {MyApp.PatternExtractor, patterns: [...]}
```

### Custom Community Detector

```elixir
defmodule MyApp.LouvainDetector do
  @behaviour Arcana.Graph.CommunityDetector

  @impl true
  def detect(entities, relationships, opts) do
    resolution = Keyword.get(opts, :resolution, 0.5)
    # Louvain algorithm...
    {:ok, communities}
  end
end

# Configure globally
config :arcana, :graph,
  community_detector: {MyApp.LouvainDetector, resolution: 0.5}
```

### Inline Functions

All extractors also support inline functions:

```elixir
# Inline entity extractor
entity_extractor = fn text, _opts ->
  {:ok, [%{name: "Example", type: :concept}]}
end

# Inline relationship extractor
relationship_extractor = fn text, entities, _opts ->
  {:ok, [%{source: "A", target: "B", type: "RELATES_TO"}]}
end

Graph.build(chunks,
  entity_extractor: entity_extractor,
  relationship_extractor: relationship_extractor
)
```

## Telemetry

GraphRAG emits telemetry events for observability:

- `[:arcana, :graph, :entity_extraction, :start | :stop | :exception]`
- `[:arcana, :graph, :relationship_extraction, :start | :stop | :exception]`
- `[:arcana, :graph, :community_detection, :start | :stop | :exception]`

Attach handlers to monitor performance:

```elixir
:telemetry.attach(
  "graph-metrics",
  [:arcana, :graph, :entity_extraction, :stop],
  fn _event, measurements, metadata, _config ->
    Logger.info("Extracted #{metadata.entity_count} entities in #{measurements.duration}ms")
  end,
  nil
)
```
