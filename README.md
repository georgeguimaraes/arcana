# Arcana 🔮📚

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fgeorgeguimaraes%2Farcana%2Fblob%2Fmain%2Flivebooks%2Farcana_tutorial.livemd)

Embeddable RAG library for Elixir/Phoenix. Add vector search, document retrieval, and AI-powered question answering to any Phoenix application. Supports both simple RAG and agentic RAG with query expansion, self-correction, and multi-step reasoning.

## Features

- **Simple API** - `ingest/2`, `search/2`, `ask/2` for basic RAG
- **Agentic RAG** - Pipeline with query expansion, decomposition, re-ranking, and self-correction
- **Hybrid search** - Vector, full-text, or combined with Reciprocal Rank Fusion
- **Multiple backends** - pgvector (default) or in-memory HNSWLib
- **Configurable embeddings** - Local Bumblebee, OpenAI, or custom providers
- **File ingestion** - Text, Markdown, and PDF support
- **Evaluation** - Measure retrieval quality with MRR, Recall, Precision metrics
- **Embeddable** - Uses your existing Repo, no separate database
- **LiveView Dashboard** - Optional web UI for managing documents and searching
- **Telemetry** - Built-in observability for all operations

## Installation

Add `arcana` to your dependencies:

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"},
    # Optional: for automatic setup (recommended)
    {:igniter, "~> 0.5"}
  ]
end
```

## Setup

### 1. Start PostgreSQL with pgvector

```yaml
# docker-compose.yml
services:
  postgres:
    image: pgvector/pgvector:pg16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: myapp_dev
```

### 2. Run the installer

**With Igniter (recommended):**

```bash
mix arcana.install
```

This automatically:
- Creates the database migration
- Adds the dashboard route to your router
- Creates the Postgrex types module
- Configures your repo

Then run:

```bash
mix ecto.migrate
```

**Without Igniter:**

```bash
mix arcana.install
mix ecto.migrate
```

Then follow the manual steps printed by the installer:

1. Create the Postgrex types module:

```elixir
# lib/my_app/postgrex_types.ex
Postgrex.Types.define(
  MyApp.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

2. Add to your repo config:

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  types: MyApp.PostgrexTypes
```

3. (Optional) Mount the dashboard:

```elixir
# lib/my_app_web/router.ex
scope "/arcana" do
  pipe_through [:browser]
  forward "/", ArcanaWeb.Router
end
```

### 3. Add to supervision tree (for local embeddings)

If using local Bumblebee embeddings (the default), add the serving to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    Arcana.Embedding.Local  # Starts the local embedding model
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

For OpenAI embeddings or custom providers, skip this step.

## Usage

### Ingest documents

```elixir
# Basic ingestion
{:ok, document} = Arcana.ingest("Your document content here", repo: MyApp.Repo)

# With source_id for scoping
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  source_id: "user-123"
)

# With metadata
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  metadata: %{"title" => "My Doc", "author" => "Jane"}
)

# Markdown-aware chunking
{:ok, document} = Arcana.ingest(markdown_content,
  repo: MyApp.Repo,
  format: :markdown
)

# Custom chunk size (in tokens, default: 512)
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  chunk_size: 256,
  chunk_overlap: 25
)

# Ingest from file
{:ok, document} = Arcana.ingest_file("path/to/document.pdf", repo: MyApp.Repo)

# With collection for segmentation
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  collection: "products"
)

# With collection description (helps Agent.select/2 route to the right collection)
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  collection: %{name: "api", description: "REST API reference documentation"}
)
```

#### Chunking Options

| Option | Default | Description |
|--------|---------|-------------|
| `:format` | `:plaintext` | Text format: `:plaintext`, `:markdown`, `:elixir`, etc. |
| `:chunk_size` | `450` | Maximum chunk size in tokens |
| `:chunk_overlap` | `50` | Overlap between chunks in tokens |
| `:size_unit` | `:tokens` | Size measurement: `:tokens` or `:characters` |
| `:collection` | `"default"` | Collection name (string) or map with `:name` and `:description` |

#### Supported File Formats

| Extension | Content Type |
|-----------|--------------|
| `.txt` | text/plain |
| `.md`, `.markdown` | text/markdown |
| `.pdf` | application/pdf (requires poppler) |

#### PDF Support (Optional)

PDF parsing requires `pdftotext` from the Poppler library. Install it for your platform:

```bash
# macOS
brew install poppler

# Ubuntu/Debian
apt-get install poppler-utils

# Fedora
dnf install poppler-utils
```

Check if PDF support is available:

```elixir
Arcana.Parser.pdf_support_available?()
# => true or false
```

If poppler is not installed, `ingest_file/2` returns `{:error, :pdf_support_not_available}` for PDF files.

### Search

```elixir
# Basic search (semantic by default)
results = Arcana.search("your query", repo: MyApp.Repo)

# Returns list of:
# %{
#   id: "chunk-uuid",
#   text: "matching chunk text...",
#   document_id: "doc-uuid",
#   chunk_index: 0,
#   score: 0.89
# }

# With options
results = Arcana.search("query",
  repo: MyApp.Repo,
  limit: 5,
  source_id: "user-123",
  threshold: 0.5,
  collection: "products"  # Filter by collection
)
```

#### Search Modes

Arcana supports three search modes, all working with both pgvector and memory backends:

```elixir
# Semantic search (default) - finds similar meaning
results = Arcana.search("query", repo: MyApp.Repo, mode: :semantic)

# Full-text search - finds exact keyword matches
results = Arcana.search("query", repo: MyApp.Repo, mode: :fulltext)

# Hybrid search - combines both with RRF fusion
results = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)

# Override vector store per-call (useful for testing)
results = Arcana.search("query",
  vector_store: {:memory, pid: memory_pid},
  mode: :semantic
)
```

| Mode | Best for | pgvector | memory |
|------|----------|----------|--------|
| `:semantic` | Conceptual queries | Cosine similarity via HNSW | HNSWLib approximate k-NN |
| `:fulltext` | Exact terms, names | PostgreSQL tsvector/tsquery | TF-IDF term matching |
| `:hybrid` | General purpose | Reciprocal Rank Fusion of both | RRF of both |

**Hybrid search** uses [Reciprocal Rank Fusion (RRF)](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) to combine results. RRF scores by rank position (`1/(k + rank)`) rather than raw scores, making it robust when combining different scoring scales.

### Delete

```elixir
:ok = Arcana.delete(document_id, repo: MyApp.Repo)
{:error, :not_found} = Arcana.delete(invalid_id, repo: MyApp.Repo)
```

### Ask (Simple RAG)

```elixir
# Using a model string (requires req_llm dependency)
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini"
)

# With custom prompt
custom_prompt = fn question, context ->
  "Answer '#{question}' using: #{Enum.map_join(context, ", ", & &1.text)}"
end
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini",
  prompt: custom_prompt
)
```

### Agentic RAG

For complex questions, use the Agent pipeline with self-correcting search, question decomposition, and collection selection:

```elixir
llm = fn prompt -> {:ok, "LLM response"} end

ctx =
  Arcana.Agent.new("Compare Elixir and Erlang features", repo: MyApp.Repo, llm: llm)
  |> Arcana.Agent.select(collections: ["elixir-docs", "erlang-docs"])
  |> Arcana.Agent.expand()
  |> Arcana.Agent.search(self_correct: true)
  |> Arcana.Agent.answer()

ctx.answer
# => "Generated answer based on retrieved context..."
```

#### Pipeline Steps

| Step | Description |
|------|-------------|
| `new/2` | Initialize context with question and options |
| `select/2` | Select relevant collections (LLM or custom selector) |
| `expand/2` | Expand query with synonyms and related terms |
| `decompose/2` | Break complex questions into sub-questions |
| `search/2` | Execute search (with optional self-correction) |
| `rerank/2` | Re-score and filter chunks by relevance |
| `answer/2` | Generate final answer from retrieved context |

**Explicit collection selection:**

If you know which collection(s) to search, skip LLM-based selection by passing `:collection` or `:collections` directly to `search/2`:

```elixir
# Search a specific collection
ctx =
  Agent.new(question, repo: MyApp.Repo, llm: llm)
  |> Agent.search(collection: "technical_docs")
  |> Agent.answer()

# Search multiple collections
ctx =
  Agent.new(question, repo: MyApp.Repo, llm: llm)
  |> Agent.search(collections: ["docs", "faq"])
  |> Agent.answer()
```

Collection selection priority:
1. `:collection`/`:collections` option passed to `search/2`
2. `ctx.collections` (set by `select/2`)
3. Falls back to `"default"` collection

This is useful when:
- You have only one collection (no LLM selection needed)
- The user explicitly chooses which collection(s) to search
- You want deterministic routing without LLM overhead

**Custom collection selection:**

By default, `select/2` uses the LLM to pick collections. For deterministic routing based on user context or business logic, provide a custom selector:

```elixir
# Custom selector module
defmodule MyApp.TeamBasedSelector do
  @behaviour Arcana.Agent.Selector

  @impl true
  def select(_question, _collections, opts) do
    case opts[:context][:team] do
      "api" -> {:ok, ["api-reference"], "API team routing"}
      "mobile" -> {:ok, ["mobile-docs"], "Mobile team routing"}
      _ -> {:ok, ["general"], "Default routing"}
    end
  end
end

ctx
|> Agent.select(
  collections: ["api-reference", "mobile-docs", "general"],
  selector: MyApp.TeamBasedSelector,
  context: %{team: current_user.team}
)

# Or inline function
ctx
|> Agent.select(
  collections: ["docs", "api"],
  selector: fn question, _collections, _opts ->
    if question =~ "API", do: {:ok, ["api"], "API query"}, else: {:ok, ["docs"], nil}
  end
)
```

**Query expansion vs. decomposition:**

- `expand/2` adds synonyms to a single query: "ML models" → "ML machine learning artificial intelligence models"
- `decompose/2` splits into multiple queries: "What is X and how does it compare to Y?" → ["What is X?", "How does it compare to Y?"]

Use `expand/2` when queries use jargon or abbreviations. Use `decompose/2` for multi-part questions.

**Re-ranking:**

`rerank/2` improves result quality by scoring each chunk's relevance using the LLM, then filtering by threshold:

```elixir
ctx
|> Agent.search()
|> Agent.rerank(threshold: 7)  # Keep chunks scoring 7+/10
|> Agent.answer()
```

For custom re-ranking logic, provide a module or function:

```elixir
# Custom reranker module
defmodule MyApp.CrossEncoderReranker do
  @behaviour Arcana.Agent.Reranker

  @impl true
  def rerank(question, chunks, _opts) do
    # Your cross-encoder logic here
    {:ok, scored_and_filtered_chunks}
  end
end

Agent.rerank(ctx, reranker: MyApp.CrossEncoderReranker)

# Or inline function
Agent.rerank(ctx, reranker: fn question, chunks, _opts ->
  {:ok, filter_by_custom_logic(question, chunks)}
end)
```

#### Custom Prompts

All pipeline steps accept custom prompt functions:

```elixir
ctx
|> Agent.select(collections: [...], prompt: fn question, collections -> "..." end)
|> Agent.expand(prompt: fn question -> "..." end)
|> Agent.decompose(prompt: fn question -> "..." end)
|> Agent.search(
  self_correct: true,
  sufficient_prompt: fn question, chunks -> "..." end,
  rewrite_prompt: fn question, chunks -> "..." end
)
|> Agent.rerank(prompt: fn question, chunk_text -> "..." end)
|> Agent.answer(prompt: fn question, chunks -> "..." end)
```

## Evaluation

Measure and improve your retrieval quality with Arcana's evaluation system.

### Test Cases

Create test cases that pair questions with their known relevant chunks:

```elixir
# Manual test case
{:ok, test_case} = Arcana.Evaluation.create_test_case(
  repo: MyApp.Repo,
  question: "How do you manage state in Elixir?",
  relevant_chunk_ids: [chunk.id]
)

# Generate synthetic test cases using LLM
{:ok, test_cases} = Arcana.Evaluation.generate_test_cases(
  repo: MyApp.Repo,
  llm: Application.get_env(:arcana, :llm),
  sample_size: 50,
  collection: "elixir-docs"  # optional: filter by collection
)
```

Or use the mix task:

```bash
mix arcana.eval.generate --sample-size 50 --collection elixir-docs
```

### Running Evaluations

```elixir
{:ok, run} = Arcana.Evaluation.run(repo: MyApp.Repo, mode: :semantic)

run.metrics
# => %{
#   mrr: 0.76,
#   recall_at_5: 0.84,
#   precision_at_5: 0.68,
#   hit_rate_at_5: 0.91
# }
```

Or use the mix task:

```bash
mix arcana.eval.run --mode hybrid
```

### Evaluating Answer Quality

For end-to-end RAG evaluation, measure how faithful generated answers are:

```elixir
{:ok, run} = Arcana.Evaluation.run(
  repo: MyApp.Repo,
  mode: :semantic,
  evaluate_answers: true,
  llm: Application.get_env(:arcana, :llm)
)

run.metrics.faithfulness  # => 7.8 (0-10 scale)
```

### Metrics

| Metric | Description |
|--------|-------------|
| **MRR** | Mean Reciprocal Rank - average of 1/rank for first relevant result |
| **Recall@K** | Fraction of relevant chunks found in top K |
| **Precision@K** | Fraction of top K results that are relevant |
| **Hit Rate@K** | Fraction of queries with at least one relevant in top K |
| **Faithfulness** | How well answers are grounded in retrieved context (0-10) |

See the [Evaluation Guide](guides/evaluation.md) for more details.

## Telemetry

Arcana emits telemetry events for observability. All operations use `:telemetry.span/3` which automatically emits `:start`, `:stop`, and `:exception` events.

### Events

| Event | Description |
|-------|-------------|
| `[:arcana, :ingest, :*]` | Document ingestion |
| `[:arcana, :search, :*]` | Search queries |
| `[:arcana, :ask, :*]` | RAG question answering |
| `[:arcana, :embed, :*]` | Embedding generation |

### Example Handler

```elixir
defmodule MyApp.ArcanaLogger do
  require Logger

  def setup do
    events = [
      [:arcana, :ingest, :stop],
      [:arcana, :search, :stop],
      [:arcana, :ask, :stop]
    ]

    :telemetry.attach_many("arcana-logger", events, &handle_event/4, nil)
  end

  def handle_event([:arcana, :ingest, :stop], measurements, metadata, _) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("Ingested document #{metadata.document.id} in #{ms}ms")
  end

  def handle_event([:arcana, :search, :stop], measurements, metadata, _) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("Search returned #{metadata.result_count} results in #{ms}ms")
  end

  def handle_event([:arcana, :ask, :stop], measurements, metadata, _) do
    ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("RAG answered with #{metadata.context_count} chunks in #{ms}ms")
  end
end
```

See `Arcana.Telemetry` module docs for complete event documentation.

## Configuration

### Embedding Providers

Arcana supports multiple embedding providers:

```elixir
# config/config.exs

# Local Bumblebee (default) - no API keys needed
config :arcana, embedding: :local
config :arcana, embedding: {:local, model: "BAAI/bge-large-en-v1.5"}

# OpenAI (requires req_llm and OPENAI_API_KEY)
config :arcana, embedding: :openai
config :arcana, embedding: {:openai, model: "text-embedding-3-large"}

# Custom function
config :arcana, embedding: fn text ->
  # Your embedding logic
  {:ok, embedding_vector}
end

# Custom module implementing Arcana.Embedding behaviour
config :arcana, embedding: MyApp.CohereEmbedder
config :arcana, embedding: {MyApp.CohereEmbedder, api_key: "..."}
```

#### Built-in Providers

| Provider | Dimensions | Notes |
|----------|------------|-------|
| `:local` (default) | 384 | `bge-small-en-v1.5`, no API key needed |
| `:openai` | 1536 | `text-embedding-3-small`, requires API key |
| `{:openai, model: "text-embedding-3-large"}` | 3072 | Higher quality |

#### Local Model Options

All local models run via Bumblebee with no API keys required. Models are downloaded from HuggingFace on first use.

| Model | Config | Dims | Size | Notes |
|-------|--------|------|------|-------|
| **BGE Small** | `{:local, model: "BAAI/bge-small-en-v1.5"}` | 384 | 133MB | Default, best balance |
| **BGE Base** | `{:local, model: "BAAI/bge-base-en-v1.5"}` | 768 | 438MB | Better accuracy |
| **BGE Large** | `{:local, model: "BAAI/bge-large-en-v1.5"}` | 1024 | 1.3GB | Best BGE accuracy |
| **E5 Small** | `{:local, model: "intfloat/e5-small-v2"}` | 384 | 133MB | Microsoft, comparable to BGE |
| **E5 Base** | `{:local, model: "intfloat/e5-base-v2"}` | 768 | 438MB | Strong all-rounder |
| **E5 Large** | `{:local, model: "intfloat/e5-large-v2"}` | 1024 | 1.3GB | Best E5 accuracy |
| **GTE Small** | `{:local, model: "thenlper/gte-small"}` | 384 | 67MB | Smallest, fastest |
| **GTE Base** | `{:local, model: "thenlper/gte-base"}` | 768 | 220MB | Alibaba |
| **GTE Large** | `{:local, model: "thenlper/gte-large"}` | 1024 | 670MB | Best GTE accuracy |
| **MiniLM** | `{:local, model: "sentence-transformers/all-MiniLM-L6-v2"}` | 384 | 91MB | Lightweight, fast |

**Recommendations:**
- **Getting started:** Use default (`bge-small-en-v1.5`) - good quality, reasonable size
- **Resource constrained:** Use `gte-small` (67MB) or `all-MiniLM-L6-v2` (91MB)
- **Best accuracy:** Use `bge-large-en-v1.5` or `e5-large-v2` (1024 dimensions)

#### Custom Embedding Module

Implement the `Arcana.Embedding` behaviour:

```elixir
defmodule MyApp.CohereEmbedder do
  @behaviour Arcana.Embedding

  @impl true
  def embed(text, opts) do
    api_key = opts[:api_key] || System.get_env("COHERE_API_KEY")
    # Call Cohere API...
    {:ok, embedding}
  end

  @impl true
  def dimensions(_opts), do: 1024
end
```

Then configure:

```elixir
config :arcana, embedding: {MyApp.CohereEmbedder, api_key: "..."}
```

### Vector Store Backends

Arcana supports multiple vector storage backends:

```elixir
# config/config.exs

# Use pgvector (default) - requires PostgreSQL with pgvector
config :arcana, vector_store: :pgvector

# Use in-memory storage with HNSWLib - no database needed
config :arcana, vector_store: :memory
```

#### Memory Backend

The memory backend uses [hnswlib](https://github.com/elixir-nx/hnswlib) for fast approximate nearest neighbor search. It supports all three search modes:

- **Semantic**: HNSWLib with cosine similarity
- **Fulltext**: TF-IDF-like term matching with length normalization
- **Hybrid**: RRF fusion of both

Useful for:

- Testing embedding models without database migrations
- Smaller RAGs where pgvector overhead isn't justified
- Development and experimentation workflows

Add to your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}
]
```

**Note:** Data is not persisted - all vectors are lost when the process stops.

#### Custom Vector Store

Implement the `Arcana.VectorStore` behaviour for custom backends (e.g., Weaviate, Pinecone, Qdrant):

```elixir
defmodule MyApp.WeaviateStore do
  @behaviour Arcana.VectorStore

  @impl true
  def store(collection, id, embedding, metadata, opts) do
    # Store vector in Weaviate
    :ok
  end

  @impl true
  def search(collection, query_embedding, opts) do
    limit = Keyword.get(opts, :limit, 10)
    # Query Weaviate for similar vectors
    [%{id: "...", metadata: %{text: "..."}, score: 0.95}]
  end

  @impl true
  def search_text(collection, query_text, opts) do
    limit = Keyword.get(opts, :limit, 10)
    # Query Weaviate for keyword matches
    [%{id: "...", metadata: %{text: "..."}, score: 0.85}]
  end

  @impl true
  def delete(collection, id, opts) do
    # Delete from Weaviate
    :ok
  end

  @impl true
  def clear(collection, opts) do
    # Clear collection in Weaviate
    :ok
  end
end
```

Then configure:

```elixir
config :arcana, vector_store: MyApp.WeaviateStore
```

#### Direct VectorStore API

For low-level vector operations, use the VectorStore API directly:

```elixir
alias Arcana.VectorStore

# Store a vector
:ok = VectorStore.store("products", "item-1", embedding, %{text: "Widget", name: "Widget"}, repo: MyApp.Repo)

# Semantic search (cosine similarity)
results = VectorStore.search("products", query_embedding, limit: 10, repo: MyApp.Repo)

# Fulltext search (keyword matching)
results = VectorStore.search_text("products", "widget", limit: 10, repo: MyApp.Repo)

# Delete a vector
:ok = VectorStore.delete("products", "item-1", repo: MyApp.Repo)

# Clear a collection
:ok = VectorStore.clear("products", repo: MyApp.Repo)

# Per-call backend override
results = VectorStore.search("products", query_embedding,
  vector_store: {:memory, pid: memory_pid},
  limit: 10
)
```

### Other Settings

```elixir
# config/config.exs

# Use EXLA backend for Nx (recommended for performance)
config :nx, default_backend: EXLA.Backend
```

## How it works

1. **Ingest**: Text is split into overlapping chunks (default 450 tokens, 50 overlap)
2. **Embed**: Each chunk is embedded using `bge-small-en-v1.5` (384 dimensions)
3. **Store**: Chunks are stored in PostgreSQL with pgvector
4. **Search**: Query is embedded and compared using cosine similarity via HNSW index

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Your Phoenix App                     │
├─────────────────────────────────────────────────────────┤
│                    Arcana.Agent                          │
│  (select → expand → search → rerank → answer pipeline)  │
├─────────────────────────────────────────────────────────┤
│  Arcana.ask/2   │  Arcana.search/2  │  Arcana.ingest/2  │
├─────────────────┴───────────────────┴───────────────────┤
│                                                         │
│  ┌─────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │   Chunker   │  │ Embeddings      │  │   Search    │ │
│  │ (splitting) │  │ (Bumblebee)     │  │ (pgvector)  │ │
│  └─────────────┘  └─────────────────┘  └─────────────┘ │
│                                                         │
├─────────────────────────────────────────────────────────┤
│              Your Existing Ecto Repo                    │
│         PostgreSQL + pgvector extension                 │
└─────────────────────────────────────────────────────────┘
```

## Roadmap

- [x] LiveView dashboard
- [x] Hybrid search (vector + full-text with RRF)
- [x] File ingestion (text, markdown, PDF)
- [x] Telemetry events for observability
- [x] In-memory vector store (HNSWLib backend)
- [x] Query expansion (Agent.expand/2)
- [x] Re-ranking (Agent.rerank/2)
- [x] Agentic RAG
  - [x] Agent pipeline with context struct
  - [x] Self-correcting search (evaluate + retry)
  - [x] Question decomposition (multi-step)
  - [x] Collection selection
- [ ] E5 embedding model prefix support (`query:` / `passage:` prefixes)
- [ ] Additional vector store backends
  - [ ] TurboPuffer (hybrid search)
  - [ ] ChromaDB
- [ ] Async ingestion with Oban
- [ ] HyDE (Hypothetical Document Embeddings)
- [ ] GraphRAG (knowledge graph + community summaries)

## Development

```bash
# Start PostgreSQL
docker compose up -d

# Install deps
mix deps.get

# Create and migrate test database
MIX_ENV=test mix ecto.create -r Arcana.TestRepo
MIX_ENV=test mix ecto.migrate -r Arcana.TestRepo

# Run tests
mix test
```

---

## License

Copyright (c) 2025 George Guimarães

Licensed under the Apache License, Version 2.0. See LICENSE file for details.
