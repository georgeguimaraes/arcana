# Arcana

Embeddable RAG (Retrieval Augmented Generation) library for Elixir. Add vector search and document retrieval to any Phoenix application.

Similar to how Oban works - add the dependency, configure it, and embed it in your supervision tree.

## Features

- **Local embeddings** - Uses Bumblebee with `bge-small-en-v1.5` (no API keys needed)
- **pgvector storage** - HNSW index for fast similarity search
- **Hybrid search** - Vector, full-text, or combined with Reciprocal Rank Fusion
- **Simple API** - `ingest/2`, `search/2`, `delete/2`
- **Source scoping** - Filter searches by `source_id` for multi-tenant apps
- **Embeddable** - Uses your existing Repo, no separate database
- **LiveView Dashboard** - Optional web UI for managing documents and searching

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

### 3. Add to supervision tree

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    {Arcana.Embeddings.Serving, []}  # Starts the embedding model
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

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
```

#### Chunking Options

| Option | Default | Description |
|--------|---------|-------------|
| `:format` | `:plaintext` | Text format: `:plaintext`, `:markdown`, `:elixir`, etc. |
| `:chunk_size` | `450` | Maximum chunk size in tokens |
| `:chunk_overlap` | `50` | Overlap between chunks in tokens |
| `:size_unit` | `:tokens` | Size measurement: `:tokens` or `:characters` |
| `:collection` | `"default"` | Collection name for document segmentation |

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

Arcana supports three search modes:

```elixir
# Semantic search (default) - finds similar meaning
results = Arcana.search("query", repo: MyApp.Repo, mode: :semantic)

# Full-text search - finds exact keyword matches
results = Arcana.search("query", repo: MyApp.Repo, mode: :fulltext)

# Hybrid search - combines both with RRF fusion
results = Arcana.search("query", repo: MyApp.Repo, mode: :hybrid)
```

| Mode | Best for | How it works |
|------|----------|--------------|
| `:semantic` | Conceptual queries | Vector similarity via pgvector |
| `:fulltext` | Exact terms, names | PostgreSQL tsvector/tsquery |
| `:hybrid` | General purpose | Reciprocal Rank Fusion of both |

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

For complex questions, use the Agent pipeline with self-correcting search, question decomposition, and collection routing:

```elixir
llm = fn prompt -> {:ok, "LLM response"} end

ctx =
  Arcana.Agent.new("Compare Elixir and Erlang features", repo: MyApp.Repo, llm: llm)
  |> Arcana.Agent.route(collections: ["elixir-docs", "erlang-docs"])
  |> Arcana.Agent.decompose()
  |> Arcana.Agent.search(self_correct: true)
  |> Arcana.Agent.answer()

ctx.answer
# => "Generated answer based on retrieved context..."
```

#### Pipeline Steps

| Step | Description |
|------|-------------|
| `new/2` | Initialize context with question and options |
| `route/2` | LLM selects relevant collections to search |
| `decompose/2` | LLM breaks complex questions into sub-questions |
| `search/2` | Execute search (with optional self-correction) |
| `answer/2` | Generate final answer from retrieved context |

#### Custom Prompts

All pipeline steps accept custom prompt functions:

```elixir
ctx
|> Agent.route(collections: [...], prompt: fn question, collections -> "..." end)
|> Agent.decompose(prompt: fn question -> "..." end)
|> Agent.search(
  self_correct: true,
  sufficient_prompt: fn question, chunks -> "..." end,
  rewrite_prompt: fn question, chunks -> "..." end
)
|> Agent.answer(prompt: fn question, chunks -> "..." end)
```

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
│     (route → decompose → search → answer pipeline)      │
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
- [ ] Async ingestion with Oban
- [ ] Query rewriting
- [ ] HyDE (Hypothetical Document Embeddings)
- [ ] GraphRAG (knowledge graph + community summaries)
- [x] Agentic RAG
  - [x] Agent pipeline with context struct
  - [x] Self-correcting search (evaluate + retry)
  - [x] Question decomposition (multi-step)
  - [x] Collection routing

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

## License

MIT
