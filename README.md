# Arcana

Embeddable RAG (Retrieval Augmented Generation) library for Elixir. Add vector search and document retrieval to any Phoenix application.

Similar to how Oban works - add the dependency, configure it, and embed it in your supervision tree.

## Features

- **Local embeddings** - Uses Bumblebee with `bge-small-en-v1.5` (no API keys needed)
- **pgvector storage** - HNSW index for fast similarity search
- **Simple API** - `ingest/2`, `search/2`, `delete/2`
- **Source scoping** - Filter searches by `source_id` for multi-tenant apps
- **Embeddable** - Uses your existing Repo, no separate database
- **LiveView Dashboard** - Optional web UI for managing documents and searching

## Installation

Add `arcana` to your dependencies:

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"}
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

### 2. Generate the migration

```bash
mix arcana.install
mix ecto.migrate
```

### 3. Configure pgvector types

Create the Postgrex types module:

```elixir
# lib/my_app/postgrex_types.ex
Postgrex.Types.define(
  MyApp.PostgrexTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
```

Add to your repo config:

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  types: MyApp.PostgrexTypes
```

### 4. Add to supervision tree

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
```

### Search

```elixir
# Basic search
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
  threshold: 0.5
)
```

### Delete

```elixir
:ok = Arcana.delete(document_id, repo: MyApp.Repo)
{:error, :not_found} = Arcana.delete(invalid_id, repo: MyApp.Repo)
```

## Configuration

```elixir
# config/config.exs

# Use EXLA backend for Nx (recommended for performance)
config :nx, default_backend: EXLA.Backend
```

## How it works

1. **Ingest**: Text is split into overlapping chunks (default 1024 chars, 200 overlap)
2. **Embed**: Each chunk is embedded using `bge-small-en-v1.5` (384 dimensions)
3. **Store**: Chunks are stored in PostgreSQL with pgvector
4. **Search**: Query is embedded and compared using cosine similarity via HNSW index

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Your Phoenix App                     │
├─────────────────────────────────────────────────────────┤
│  Arcana.ingest/2  │  Arcana.search/2  │  Arcana.delete/2│
├───────────────────┴───────────────────┴─────────────────┤
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

- [ ] LiveView dashboard (`ArcanaWeb.Router`)
- [ ] File ingestion (PDF, DOCX)
- [ ] Hybrid search (vector + full-text with RRF)
- [ ] RAG pipeline with LLM providers
- [ ] Async ingestion with Oban

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
