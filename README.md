# Arcana 🔮📚

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fgeorgeguimaraes%2Farcana%2Fblob%2Fmain%2Flivebooks%2Farcana_tutorial.livemd)

Embeddable RAG library for Elixir/Phoenix. Add vector search, document retrieval, and AI-powered question answering to any Phoenix application. Supports both simple RAG and agentic RAG with query expansion, self-correction, and more.

> [!TIP]
> See [arcana-adept](https://github.com/georgeguimaraes/arcana-adept) for a complete Phoenix app with a Doctor Who corpus ready to embed and query.

## Features

- **Simple API** - `ingest/2`, `search/2`, `ask/2` for basic RAG
- **Agentic RAG** - Pipeline with query expansion, decomposition, re-ranking, and self-correction
- **Pluggable components** - Replace any pipeline step with custom implementations
- **Hybrid search** - Vector, full-text, or combined with Reciprocal Rank Fusion
- **Multiple backends** - pgvector (default) or in-memory HNSWLib
- **Configurable embeddings** - Local Bumblebee, OpenAI, or custom providers
- **File ingestion** - Text, Markdown, and PDF support
- **Evaluation** - Measure retrieval quality with MRR, Recall, Precision metrics
- **Embeddable** - Uses your existing Repo, no separate database
- **LiveView Dashboard** - Optional web UI for managing documents and searching
- **Telemetry** - Built-in observability for all operations

## How it works

1. **Ingest**: Text is split into overlapping chunks (default 450 tokens, 50 overlap)
2. **Embed**: Each chunk is embedded using `bge-small-en-v1.5` (384 dimensions)
3. **Store**: Chunks are stored in PostgreSQL with pgvector
4. **Search**: Query is embedded and compared using cosine similarity via HNSW index

## Installation

**With Igniter (recommended):**

```bash
mix igniter.install arcana
mix ecto.migrate
```

This adds the dependency, creates migrations, configures your repo, and sets up the dashboard route.

**Without Igniter:**

Add `arcana` to your dependencies:

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
mix arcana.install
mix ecto.migrate
```

And follow the manual steps printed by the installer:

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

## Setup

### Start PostgreSQL with pgvector

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

### Add to supervision tree (for local embeddings)

If using local Bumblebee embeddings (the default), add the serving to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    Arcana.Embedder.Local  # Starts the local embedding model
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Configure Nx backend (recommended)

For better performance with local embeddings:

```elixir
# config/config.exs
config :nx, default_backend: EXLA.Backend
```

### Embedding providers

Arcana supports multiple embedding providers:

```elixir
# config/config.exs

# Local Bumblebee (default) - no API keys needed
config :arcana, embedder: :local
config :arcana, embedder: {:local, model: "BAAI/bge-large-en-v1.5"}

# OpenAI (requires OPENAI_API_KEY)
config :arcana, embedder: :openai
config :arcana, embedder: {:openai, model: "text-embedding-3-large"}

# Custom module implementing Arcana.Embedder behaviour
config :arcana, embedder: MyApp.CohereEmbedder
```

Implement custom embedders with the `Arcana.Embedder` behaviour:

```elixir
defmodule MyApp.CohereEmbedder do
  @behaviour Arcana.Embedder

  @impl true
  def embed(text, opts) do
    # Call your embedding API
    {:ok, embedding_vector}
  end

  @impl true
  def dimensions(_opts), do: 1024
end
```

See the [Getting Started Guide](guides/getting-started.md) for all embedding model options.

### Chunking providers

Arcana supports pluggable chunking strategies:

```elixir
# config/config.exs

# Default text chunker (uses text_chunker library)
config :arcana, chunker: :default
config :arcana, chunker: {:default, chunk_size: 512, chunk_overlap: 100}

# Custom module implementing Arcana.Chunker behaviour
config :arcana, chunker: MyApp.SemanticChunker
```

Implement custom chunkers with the `Arcana.Chunker` behaviour:

```elixir
defmodule MyApp.SemanticChunker do
  @behaviour Arcana.Chunker

  @impl true
  def chunk(text, opts) do
    # Custom chunking logic (e.g., semantic boundaries)
    [
      %{text: "chunk 1", chunk_index: 0, token_count: 50},
      %{text: "chunk 2", chunk_index: 1, token_count: 45}
    ]
  end
end
```

You can also pass `:chunker` directly to `ingest/2`:

```elixir
Arcana.ingest(text, repo: MyApp.Repo, chunker: MyApp.SemanticChunker)
```

### LLM configuration

Configure the LLM for `ask/2` and the Agent pipeline:

```elixir
# config/config.exs

# Model string (requires req_llm dependency)
config :arcana, llm: "openai:gpt-4o-mini"
config :arcana, llm: "anthropic:claude-sonnet-4-20250514"

# Function that takes a prompt and returns {:ok, response}
config :arcana, llm: fn prompt ->
  {:ok, MyApp.LLM.complete(prompt)}
end

# Custom module implementing Arcana.LLM behaviour
config :arcana, llm: MyApp.CustomLLM
```

You can also pass `:llm` directly to functions:

```elixir
Arcana.ask("What is Elixir?", repo: MyApp.Repo, llm: "openai:gpt-4o")

Agent.new(question, repo: MyApp.Repo, llm: fn prompt -> ... end)
```

See the [LLM Integration Guide](guides/llm-integration.md) for detailed examples.

## Usage

### Ingest documents

```elixir
# Basic ingestion
{:ok, document} = Arcana.ingest("Your document content here", repo: MyApp.Repo)

# With metadata and collection
{:ok, document} = Arcana.ingest(content,
  repo: MyApp.Repo,
  metadata: %{"title" => "My Doc", "author" => "Jane"},
  collection: "products"
)

# Ingest from file (supports .txt, .md, .pdf)
{:ok, document} = Arcana.ingest_file("path/to/document.pdf", repo: MyApp.Repo)
```

### Search

```elixir
# Semantic search (default)
{:ok, results} = Arcana.search("your query", repo: MyApp.Repo)

# Hybrid search (combines semantic + fulltext)
{:ok, results} = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)

# Hybrid with custom weights (pgvector only)
{:ok, results} = Arcana.search("query",
  repo: MyApp.Repo,
  mode: :hybrid,
  semantic_weight: 0.7,
  fulltext_weight: 0.3
)

# With filters
{:ok, results} = Arcana.search("query",
  repo: MyApp.Repo,
  limit: 5,
  collection: "products"
)
```

See the [Search Algorithms Guide](guides/search-algorithms.md) for details on search modes.

### Ask (Simple RAG)

```elixir
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini"
)
```

### Agentic RAG

For complex questions, use the Agent pipeline with query expansion, re-ranking, and self-correcting answers:

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, "LLM response"} end

ctx =
  Agent.new("Compare Elixir and Erlang features", repo: MyApp.Repo, llm: llm)
  |> Agent.select(collections: ["elixir-docs", "erlang-docs"])
  |> Agent.expand()
  |> Agent.search()
  |> Agent.rerank()
  |> Agent.answer(self_correct: true)

ctx.answer
# => "Generated answer based on retrieved context..."
```

#### Pipeline Steps

| Step | What it does |
|------|--------------|
| `new/2` | Initialize context with question, repo, and LLM function |
| `rewrite/2` | Clean up conversational input ("Hey, can you tell me about X?" → "about X") |
| `select/2` | Choose which collections to search (LLM picks based on collection descriptions) |
| `expand/2` | Add synonyms and related terms ("ML models" → "ML machine learning models algorithms") |
| `decompose/2` | Split complex questions ("What is X and how does Y work?" → ["What is X?", "How does Y work?"]) |
| `search/2` | Execute vector search across selected collections |
| `rerank/2` | Score each chunk's relevance (0-10) and filter below threshold |
| `answer/2` | Generate final answer; with `self_correct: true`, evaluates and refines if not grounded |

#### Example: Building a Pipeline

```elixir
# Simple pipeline - just search and answer
ctx =
  Agent.new(question, repo: MyApp.Repo, llm: llm)
  |> Agent.search(collection: "docs")
  |> Agent.answer()

# Full pipeline with all steps
ctx =
  Agent.new(question, repo: MyApp.Repo, llm: llm)
  |> Agent.rewrite()                              # Clean up conversational input
  |> Agent.select(collections: available_collections)  # Pick relevant collections
  |> Agent.expand()                               # Add synonyms
  |> Agent.decompose()                            # Split multi-part questions
  |> Agent.search()                               # Search each sub-question
  |> Agent.rerank(threshold: 7)                   # Keep chunks scoring 7+/10
  |> Agent.answer(self_correct: true)             # Generate and verify answer

# Access results
ctx.answer           # Final answer
ctx.chunks           # Retrieved chunks after reranking
ctx.sub_questions    # Sub-questions from decomposition
ctx.correction_count # Number of self-correction iterations
```

#### Custom Components

Every pipeline step can be replaced with a custom module or function:

```elixir
# Custom reranker using a cross-encoder model
defmodule MyApp.CrossEncoderReranker do
  @behaviour Arcana.Agent.Reranker

  @impl true
  def rerank(question, chunks, _opts) do
    scored = Enum.map(chunks, fn chunk ->
      score = MyApp.CrossEncoder.score(question, chunk.text)
      {chunk, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0.5 end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.map(fn {chunk, _} -> chunk end)

    {:ok, scored}
  end
end

ctx |> Agent.rerank(reranker: MyApp.CrossEncoderReranker)

# Or use an inline function
ctx |> Agent.rerank(reranker: fn question, chunks, _opts ->
  {:ok, Enum.filter(chunks, &relevant?(&1, question))}
end)
```

All steps support custom implementations via behaviours:

| Step | Behaviour | Option |
|------|-----------|--------|
| `rewrite/2` | `Arcana.Agent.Rewriter` | `:rewriter` |
| `select/2` | `Arcana.Agent.Selector` | `:selector` |
| `expand/2` | `Arcana.Agent.Expander` | `:expander` |
| `decompose/2` | `Arcana.Agent.Decomposer` | `:decomposer` |
| `search/2` | `Arcana.Agent.Searcher` | `:searcher` |
| `rerank/2` | `Arcana.Agent.Reranker` | `:reranker` |
| `answer/2` | `Arcana.Agent.Answerer` | `:answerer` |

See the [Agentic RAG Guide](guides/agentic-rag.md) for detailed examples.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Your Phoenix App                    │
├─────────────────────────────────────────────────────────┤
│                    Arcana.Agent                         │
│  (rewrite → select → expand → search → rerank → answer) │
├─────────────────────────────────────────────────────────┤
│  Arcana.ask/2   │  Arcana.search/2  │  Arcana.ingest/2  │
├─────────────────┴───────────────────┴───────────────────┤
│                                                         │
│  ┌─────────────┐  ┌─────────────────┐  ┌─────────────┐  │
│  │   Chunker   │  │   Embeddings    │  │   Search    │  │
│  │ (splitting) │  │   (Bumblebee)   │  │ (pgvector)  │  │
│  └─────────────┘  └─────────────────┘  └─────────────┘  │
│                                                         │
├─────────────────────────────────────────────────────────┤
│              Your Existing Ecto Repo                    │
│         PostgreSQL + pgvector extension                 │
└─────────────────────────────────────────────────────────┘
```

## Guides

- [Getting Started](guides/getting-started.md) - Installation, embedding models, basic usage
- [Agentic RAG](guides/agentic-rag.md) - Build sophisticated RAG pipelines
- [LLM Integration](guides/llm-integration.md) - Connect to OpenAI, Anthropic, or custom LLMs
- [Search Algorithms](guides/search-algorithms.md) - Semantic, fulltext, and hybrid search
- [Re-ranking](guides/reranking.md) - Improve retrieval quality
- [Evaluation](guides/evaluation.md) - Measure and improve retrieval quality
- [Telemetry](guides/telemetry.md) - Observability, metrics, and debugging
- [Dashboard](guides/dashboard.md) - Web UI setup

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
  - [x] Self-correcting answers (evaluate + refine)
  - [x] Question decomposition (multi-step)
  - [x] Collection selection
  - [x] Pluggable components (custom behaviours for all steps)
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
