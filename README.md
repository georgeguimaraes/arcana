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
- **GraphRAG** - Optional knowledge graph with entity extraction, community detection, and fusion search
- **Multiple backends** - Swappable vector store (pgvector, in-memory HNSWLib) and graph store (Ecto, in-memory) backends
- **Configurable embeddings** - Local Bumblebee, OpenAI, or custom providers
- **File ingestion** - Text, Markdown, and PDF support
- **Evaluation** - Measure retrieval quality with MRR, Recall, Precision metrics
- **Embeddable** - Uses your existing Repo, no separate database
- **LiveView Dashboard** - Optional web UI for managing documents and searching
- **Telemetry** - Built-in observability for all operations

## How it works

### Basic RAG Pipeline

1. **Chunk**: Text is split into overlapping segments (default 450 tokens, 50 overlap). Pluggable chunkers support custom splitting logic.
2. **Embed**: Each chunk is embedded using configurable providers (local Bumblebee, OpenAI, or custom). E5 models automatically get `query:`/`passage:` prefixes.
3. **Store**: Embeddings are stored via swappable vector backends (pgvector for production, HNSWLib in-memory for testing).
4. **Search**: Query embedding is compared using cosine similarity. Supports semantic, full-text, and hybrid modes with Reciprocal Rank Fusion.

### GraphRAG (Optional)

When `graph: true` is enabled:
1. **Extract**: Named entities (people, orgs, technologies) are extracted via NER or LLM
2. **Link**: Relationships between entities are detected and stored
3. **Community**: Entities are clustered using the Leiden algorithm
4. **Fuse**: Vector search and graph traversal results are combined with RRF

### Agentic Pipeline

For complex questions, the Agent pipeline provides:
- **Retrieval gating** - decides if retrieval is needed or can answer from knowledge
- **Query expansion** - adds synonyms and related terms
- **Decomposition** - splits multi-part questions
- **Multi-hop reasoning** - evaluates results and searches again if needed
- **Re-ranking** - scores chunk relevance (0-10)

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
    {:arcana, "~> 1.0"}
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

### Add to supervision tree

Add Arcana components to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    Arcana.TaskSupervisor,  # Required for dashboard async operations
    Arcana.Embedder.Local   # Only if using local Bumblebee embeddings
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

`Arcana.TaskSupervisor` is required for the dashboard's async operations (Ask, Maintenance).
`Arcana.Embedder.Local` is only needed if using local Bumblebee embeddings (the default).

### Configure Nx backend (required for local embeddings)

For local embeddings, you need an Nx backend. Choose **one** of the following:

```elixir
# config/config.exs

# Option 1: EXLA - Google's XLA compiler (Linux/macOS/Windows)
config :nx,
  default_backend: EXLA.Backend,
  default_defn_options: [compiler: EXLA]

# Option 2: EMLX - Apple's MLX framework (macOS with Apple Silicon only)
config :nx,
  default_backend: EMLX.Backend,
  default_defn_options: [compiler: EMLX]

# Option 3: Torchx - PyTorch backend (no compiler, uses eager execution)
config :nx,
  default_backend: {Torchx.Backend, device: :cpu}  # or :mps for Apple Silicon
```

Add the corresponding dependency to your `mix.exs`:

```elixir
{:exla, "~> 0.9"}    # or
{:emlx, "~> 0.1"}    # or
{:torchx, "~> 0.9"}
```

### Embedding providers

Arcana supports multiple embedding providers:

```elixir
# config/config.exs

# Local Bumblebee (default) - no API keys needed
config :arcana, embedder: :local
config :arcana, embedder: {:local, model: "BAAI/bge-large-en-v1.5"}

# E5 models (automatically adds query:/passage: prefixes)
config :arcana, embedder: {:local, model: "intfloat/e5-small-v2"}

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

### PDF parsing

Arcana supports PDF ingestion with pluggable parsers. The default uses Poppler's `pdftotext`:

```elixir
# config/config.exs

# Default: Poppler (requires pdftotext installed)
config :arcana, pdf_parser: :poppler
config :arcana, pdf_parser: {:poppler, layout: true}

# Custom module implementing Arcana.FileParser.PDF behaviour
config :arcana, pdf_parser: MyApp.PDFParser
config :arcana, pdf_parser: {MyApp.PDFParser, some_option: "value"}
```

**Installing Poppler:**

```bash
# macOS
brew install poppler

# Ubuntu/Debian
apt-get install poppler-utils

# Fedora
dnf install poppler-utils
```

**Custom PDF parsers** implement the `Arcana.FileParser.PDF` behaviour:

```elixir
defmodule MyApp.PDFParser do
  @behaviour Arcana.FileParser.PDF

  @impl true
  def parse(path, opts) do
    # Your PDF parsing logic (e.g., using pdf2htmlex, Apache PDFBox, etc.)
    {:ok, extracted_text}
  end

  # Optional: support binary content (default: false)
  def supports_binary?, do: true
end
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

# With GraphRAG (extracts entities and relationships)
{:ok, document} = Arcana.ingest(content, repo: MyApp.Repo, graph: true)
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

# With GraphRAG (combines vector + graph search with RRF)
{:ok, results} = Arcana.search("query", repo: MyApp.Repo, graph: true)
```

See the [Search Algorithms Guide](guides/search-algorithms.md) for details on search modes.

### GraphRAG

GraphRAG enhances retrieval by building a knowledge graph from your documents. Entities (people, organizations, technologies) and their relationships are extracted during ingestion, then used alongside vector search for more contextual results.

```elixir
# Install GraphRAG tables
mix arcana.graph.install
mix ecto.migrate

# Ingest with graph building
{:ok, document} = Arcana.ingest(content, repo: MyApp.Repo, graph: true)

# Search combines vector + graph traversal with Reciprocal Rank Fusion
{:ok, results} = Arcana.search("Who leads OpenAI?", repo: MyApp.Repo, graph: true)
```

Components are pluggable: swap entity extractors (NER, LLM), relationship extractors, community detectors (Leiden), and summarizers with your own implementations.

See the [GraphRAG Guide](guides/graphrag.md) for entity extraction, community detection, and fusion search.

### Ask (Simple RAG)

```elixir
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini"
)
```

### Agentic RAG

For complex questions, use the Agent pipeline with retrieval gating, query expansion, multi-hop reasoning, and re-ranking:

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, "LLM response"} end

ctx =
  Agent.new("Compare Elixir and Erlang features", repo: MyApp.Repo, llm: llm)
  |> Agent.gate()                                   # Skip retrieval if not needed
  |> Agent.select(collections: ["elixir-docs", "erlang-docs"])
  |> Agent.expand()
  |> Agent.search()
  |> Agent.reason()                                 # Search again if results insufficient
  |> Agent.rerank()
  |> Agent.answer()

ctx.answer
# => "Generated answer based on retrieved context..."
```

#### Pipeline Steps

| Step | What it does |
|------|--------------|
| `new/2` | Initialize context with question, repo, and LLM function |
| `gate/2` | Decide if retrieval is needed; sets `skip_retrieval: true` if answerable from knowledge |
| `rewrite/2` | Clean up conversational input ("Hey, can you tell me about X?" → "about X") |
| `select/2` | Choose which collections to search (LLM picks based on collection descriptions) |
| `expand/2` | Add synonyms and related terms ("ML models" → "ML machine learning models algorithms") |
| `decompose/2` | Split complex questions ("What is X and how does Y work?" → ["What is X?", "How does Y work?"]) |
| `search/2` | Execute vector search (skipped if `skip_retrieval: true`) |
| `reason/2` | Multi-hop reasoning; evaluates if results are sufficient and searches again if needed |
| `rerank/2` | Score each chunk's relevance (0-10) and filter below threshold |
| `answer/2` | Generate final answer using retrieved context (or from knowledge if `skip_retrieval: true`) |

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
  |> Agent.gate()                                 # Decide if retrieval needed
  |> Agent.rewrite()                              # Clean up conversational input
  |> Agent.select(collections: available_collections)  # Pick relevant collections
  |> Agent.expand()                               # Add synonyms
  |> Agent.decompose()                            # Split multi-part questions
  |> Agent.search()                               # Search each sub-question
  |> Agent.reason()                               # Multi-hop: search again if needed
  |> Agent.rerank(threshold: 7)                   # Keep chunks scoring 7+/10
  |> Agent.answer()                               # Generate answer

# Access results
ctx.answer           # Final answer
ctx.skip_retrieval   # true if gate/2 determined no retrieval needed
ctx.sub_questions    # Sub-questions from decomposition
ctx.reason_iterations # Number of additional searches by reason/2
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
- [GraphRAG](guides/graphrag.md) - Knowledge graphs with entity extraction and community detection
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
- [x] E5 embedding model prefix support (`query:` / `passage:` prefixes)
- [ ] Additional vector store backends
  - [ ] TurboPuffer (hybrid search)
  - [ ] ChromaDB
- [ ] Async ingestion with Oban
- [ ] HyDE (Hypothetical Document Embeddings)
- [x] GraphRAG (knowledge graph + community summaries)

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
