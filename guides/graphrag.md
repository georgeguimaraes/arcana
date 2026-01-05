# GraphRAG

Build knowledge graphs from documents for enhanced retrieval with entity extraction, relationship mapping, and community detection.

## Overview

GraphRAG enhances traditional vector search by building a knowledge graph from your documents. This allows:

- **Entity-based retrieval** - Find chunks by following entity relationships
- **Community summaries** - High-level context about clusters of related entities
- **Fusion search** - Combine vector and graph results with Reciprocal Rank Fusion

## Quick Start

Once installed and configured, GraphRAG integrates seamlessly with the existing API:

```elixir
# Ingest with graph building - extracts entities and relationships automatically
{:ok, document} = Arcana.ingest(content, repo: MyApp.Repo, graph: true)

# Search with fusion - combines vector similarity + entity graph traversal
{:ok, results} = Arcana.search("Who leads OpenAI?", repo: MyApp.Repo, graph: true)
```

When `graph: true` is enabled:
- **Ingest** extracts entities (people, organizations, etc.) and relationships from each chunk
- **Search** finds entities in your query, traverses the graph, and combines results with vector search using Reciprocal Rank Fusion (RRF)

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
  Arcana.TaskSupervisor,
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

GraphRAG uses pluggable behaviours for extraction and community detection:

| Component | Default | Purpose |
|-----------|---------|---------|
| GraphExtractor | `Arcana.Graph.GraphExtractor.LLM` | Extract entities + relationships in one LLM call |
| EntityExtractor | `Arcana.Graph.EntityExtractor.NER` | Extract entities only (fallback) |
| RelationshipExtractor | `Arcana.Graph.RelationshipExtractor.LLM` | Find relationships (fallback) |
| CommunityDetector | `Arcana.Graph.CommunityDetector.Leiden` | Detect entity communities |
| CommunitySummarizer | `Arcana.Graph.CommunitySummarizer.LLM` | Generate community summaries |

**Recommended:** Use the combined `GraphExtractor.LLM` for efficiency (1 LLM call per chunk instead of 2).

## Graph Storage

GraphRAG supports swappable storage backends for graph data:

| Backend | Purpose |
|---------|---------|
| `:ecto` (default) | PostgreSQL persistence via Ecto |
| `:memory` | In-memory storage for testing |
| Custom module | Your own implementation |

### Configuration

```elixir
# config/config.exs

# Use Ecto/PostgreSQL (default)
config :arcana, :graph_store, :ecto

# With options
config :arcana, :graph_store, {:ecto, repo: MyApp.Repo}

# Custom module
config :arcana, :graph_store, MyApp.CustomGraphStore
```

### In-Memory Backend (Testing)

The memory backend is useful for testing without database dependencies:

```elixir
# Start a memory store
{:ok, pid} = Arcana.Graph.GraphStore.Memory.start_link([])

# Use in tests
Arcana.ingest(text, graph_store: {:memory, pid: pid})
Arcana.search(query, graph_store: {:memory, pid: pid})

# Or with a named process
{:ok, _} = Arcana.Graph.GraphStore.Memory.start_link(name: :test_graph)
Arcana.ingest(text, graph_store: {:memory, name: :test_graph})
```

### Custom Backend

Implement the `Arcana.Graph.GraphStore` behaviour. The full interface includes storage, query, deletion, and listing callbacks:

```elixir
defmodule MyApp.Neo4jGraphStore do
  @behaviour Arcana.Graph.GraphStore

  # === Storage Callbacks ===

  @impl true
  def persist_entities(collection_id, entities, opts) do
    # Store entities, return map of entity names to assigned IDs
    {:ok, %{"Sam Altman" => "entity_123", "OpenAI" => "entity_456"}}
  end

  @impl true
  def persist_relationships(relationships, entity_id_map, opts) do
    # Store relationships between entities
    :ok
  end

  @impl true
  def persist_mentions(mentions, entity_id_map, opts) do
    # Store entity-chunk mentions (links entities to source chunks)
    :ok
  end

  @impl true
  def persist_communities(collection_id, communities, opts) do
    # Store community detection results
    :ok
  end

  # === Query Callbacks ===

  @impl true
  def search(entity_names, collection_ids, opts) do
    # Find chunks by entity names
    [%{chunk_id: "chunk_123", score: 0.9}]
  end

  @impl true
  def find_entities(collection_id, opts) do
    # Return all entities in collection
    [%{id: "entity_123", name: "Sam Altman", type: "person"}]
  end

  @impl true
  def find_related_entities(entity_id, depth, opts) do
    # Traverse graph to find related entities
    [%{id: "entity_456", name: "OpenAI", type: "organization"}]
  end

  @impl true
  def get_community_summaries(collection_id, opts) do
    # Return community summaries
    [%{id: "community_1", level: 0, summary: "AI research organizations..."}]
  end

  # === Detail Query Callbacks ===

  @impl true
  def get_entity(entity_id, opts) do
    {:ok, %{id: entity_id, name: "Sam Altman", type: "person"}}
  end

  @impl true
  def get_relationships(entity_id, opts) do
    [%{id: "rel_1", source_id: entity_id, target_id: "entity_456", type: "LEADS"}]
  end

  @impl true
  def get_relationship(relationship_id, opts) do
    {:ok, %{id: relationship_id, source_id: "entity_123", target_id: "entity_456", type: "LEADS"}}
  end

  @impl true
  def get_mentions(entity_id, opts) do
    [%{entity_id: entity_id, chunk_id: "chunk_123", chunk_text: "..."}]
  end

  @impl true
  def get_community(community_id, opts) do
    {:ok, %{id: community_id, level: 0, summary: "..."}}
  end

  # === List Callbacks (for UI/Dashboard) ===

  @impl true
  def list_entities(opts) do
    # Support :collection_id, :type, :search, :limit, :offset options
    [%{id: "entity_123", name: "Sam Altman", type: "person", mention_count: 5}]
  end

  @impl true
  def list_relationships(opts) do
    # Support :collection_id, :type, :search, :strength, :limit, :offset options
    [%{id: "rel_1", source_name: "Sam Altman", target_name: "OpenAI", type: "LEADS"}]
  end

  @impl true
  def list_communities(opts) do
    # Support :collection_id, :level, :search, :limit, :offset options
    [%{id: "community_1", level: 0, entity_count: 10, summary: "..."}]
  end

  # === Deletion Callbacks ===

  @impl true
  def delete_by_chunks(chunk_ids, opts) do
    # Delete mentions for chunks, cleanup orphaned entities
    :ok
  end

  @impl true
  def delete_by_collection(collection_id, opts) do
    # Delete all graph data for a collection
    :ok
  end
end
```

See `Arcana.Graph.GraphStore` for the complete callback documentation.

## Building a Graph

### Combined Extraction (Recommended)

The combined `GraphExtractor.LLM` extracts entities and relationships in a single LLM call per chunk:

```elixir
# config/runtime.exs - Enable combined extractor globally
config :arcana,
  llm: {"openai:gpt-4o-mini", api_key: System.get_env("OPENAI_API_KEY")},
  graph: [
    enabled: true,
    extractor: Arcana.Graph.GraphExtractor.LLM
  ]

# The LLM is automatically injected from the :arcana, :llm config
```

Or use programmatically:

```elixir
alias Arcana.Graph.GraphBuilder

# Build graph with combined extractor
{:ok, graph_data} = GraphBuilder.build(chunks,
  extractor: {Arcana.Graph.GraphExtractor.LLM, llm: my_llm}
)

# Returns:
# %{
#   entities: [%{name: "Sam Altman", type: "person", description: "CEO of OpenAI"}],
#   relationships: [%{source: "Sam Altman", target: "OpenAI", type: "LEADS", strength: 9}],
#   mentions: [%{entity_name: "Sam Altman", chunk_id: "chunk_123"}]
# }
```

### Separate Extractors (Fallback)

If `extractor` is not set, Arcana falls back to separate entity and relationship extractors:

```elixir
# Build graph with separate extractors
{:ok, graph_data} = GraphBuilder.build(chunks,
  entity_extractor: {Arcana.Graph.EntityExtractor.NER, []},
  relationship_extractor: {Arcana.Graph.RelationshipExtractor.LLM, llm: my_llm}
)
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

### Custom GraphExtractor (Combined)

```elixir
defmodule MyApp.CustomGraphExtractor do
  @behaviour Arcana.Graph.GraphExtractor

  @impl true
  def extract(text, opts) do
    # Your extraction logic - return both entities and relationships
    entities = extract_entities(text, opts)
    relationships = extract_relationships(text, entities, opts)
    {:ok, %{entities: entities, relationships: relationships}}
  end
end

# Configure globally
config :arcana, :graph,
  extractor: MyApp.CustomGraphExtractor
```

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

### Custom Community Summarizer

```elixir
defmodule MyApp.ExtractiveSum do
  @behaviour Arcana.Graph.CommunitySummarizer

  @impl true
  def summarize(entities, relationships, opts) do
    max_sentences = Keyword.get(opts, :max_sentences, 3)
    # Extractive summarization from entity descriptions...
    {:ok, summary}
  end
end

# Configure globally
config :arcana, :graph,
  community_summarizer: {MyApp.ExtractiveSum, max_sentences: 3}

# Or disable summarization entirely
config :arcana, :graph,
  community_summarizer: nil
```

### Inline Functions

All extractors also support inline functions:

```elixir
# Inline combined extractor (recommended)
extractor = fn text, _opts ->
  {:ok, %{
    entities: [%{name: "Example", type: :concept}],
    relationships: [%{source: "A", target: "B", type: "RELATES_TO"}]
  }}
end

GraphBuilder.build(chunks, extractor: extractor)

# Or use separate inline extractors
entity_extractor = fn text, _opts ->
  {:ok, [%{name: "Example", type: :concept}]}
end

relationship_extractor = fn text, entities, _opts ->
  {:ok, [%{source: "A", target: "B", type: "RELATES_TO"}]}
end

GraphBuilder.build(chunks,
  entity_extractor: entity_extractor,
  relationship_extractor: relationship_extractor
)

# Inline community summarizer
summarizer = fn entities, relationships, _opts ->
  {:ok, "Community with #{length(entities)} entities"}
end

CommunitySummarizer.summarize(entities, relationships, community_summarizer: summarizer)
```

## Telemetry

GraphRAG emits telemetry events for observability.

### Graph Building Events

- `[:arcana, :graph, :build, :start | :stop | :exception]` - Full graph build
- `[:arcana, :graph, :ner, :start | :stop | :exception]` - Named entity recognition
- `[:arcana, :graph, :relationship_extraction, :start | :stop | :exception]` - Relationship extraction
- `[:arcana, :graph, :community_detection, :start | :stop | :exception]` - Community detection
- `[:arcana, :graph, :community_summary, :start | :stop | :exception]` - Community summarization

### Graph Search Events

- `[:arcana, :graph, :search, :start | :stop | :exception]` - Graph-enhanced search

### Graph Store Events

These events are emitted by the storage layer:

- `[:arcana, :graph_store, :persist_entities, :start | :stop | :exception]`
- `[:arcana, :graph_store, :persist_relationships, :start | :stop | :exception]`
- `[:arcana, :graph_store, :persist_mentions, :start | :stop | :exception]`
- `[:arcana, :graph_store, :search, :start | :stop | :exception]`
- `[:arcana, :graph_store, :delete_by_chunks, :start | :stop | :exception]`
- `[:arcana, :graph_store, :delete_by_collection, :start | :stop | :exception]`

### Example Handler

```elixir
:telemetry.attach(
  "graph-metrics",
  [:arcana, :graph, :build, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("Built graph: #{metadata.entity_count} entities, #{metadata.relationship_count} relationships in #{duration_ms}ms")
  end,
  nil
)
```

See the [Telemetry Guide](telemetry.md) for more details on monitoring and metrics integration.

## Maintenance Tasks

GraphRAG provides mix tasks for managing the knowledge graph.

### Rebuild Graph

Re-extract entities and relationships from all chunks:

```bash
# Rebuild all collections
mix arcana.graph.rebuild

# Rebuild specific collection
mix arcana.graph.rebuild --collection my-docs

# Resume interrupted rebuild
mix arcana.graph.rebuild --resume
```

Use this when:
- You've changed the graph extractor configuration
- You want to regenerate entity/relationship data
- You've enabled relationship extraction after initial ingest

### Detect Communities

Run Leiden community detection on the graph:

```bash
# Detect communities for all collections
mix arcana.graph.detect_communities

# Specific collection
mix arcana.graph.detect_communities --collection my-docs

# Custom resolution (higher = smaller communities)
mix arcana.graph.detect_communities --resolution 1.5

# Multiple hierarchy levels
mix arcana.graph.detect_communities --max-level 3
```

### Summarize Communities

Generate LLM summaries for detected communities:

```bash
# Summarize dirty communities (those needing regeneration)
mix arcana.graph.summarize_communities

# Force regenerate all summaries
mix arcana.graph.summarize_communities --force

# Specific collection
mix arcana.graph.summarize_communities --collection my-docs

# Parallel summarization (faster)
mix arcana.graph.summarize_communities --concurrency 4

# Quiet mode (less output)
mix arcana.graph.summarize_communities --quiet
```

Requires an LLM to be configured:

```elixir
config :arcana, :llm, {"openai:gpt-4o-mini", api_key: "..."}
```

### Typical Workflow

After ingesting new documents:

```bash
# 1. Detect communities in the graph
mix arcana.graph.detect_communities

# 2. Generate summaries for communities
mix arcana.graph.summarize_communities
```

To refresh everything:

```bash
# 1. Rebuild the graph (re-extract entities/relationships)
mix arcana.graph.rebuild

# 2. Re-detect communities
mix arcana.graph.detect_communities

# 3. Regenerate all summaries
mix arcana.graph.summarize_communities --force
```
