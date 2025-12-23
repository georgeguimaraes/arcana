# Minimal RAG Loop Design

## Overview

Arcana is an embeddable Elixir library that adds RAG (Retrieval Augmented Generation) capabilities to any Phoenix/Ecto app. Similar to how Oban works - add the dependency, configure it, add to your supervision tree.

## Usage

```elixir
# mix.exs
{:arcana, "~> 0.1"}

# config.exs
config :arcana,
  repo: MyApp.Repo,
  embedding_model: "BAAI/bge-small-en-v1.5"

# application.ex
children = [
  MyApp.Repo,
  {Arcana, repo: MyApp.Repo}
]

# router.ex (optional)
scope "/arcana" do
  forward "/", ArcanaWeb.Router
end
```

## Phase 1 Scope (Minimal RAG Loop)

Prove the core pipeline works:
- `Arcana.ingest(text, opts)` - chunk, embed, store
- `Arcana.search(query, opts)` - vector similarity search
- `Arcana.delete(document_id)` - remove document and chunks

No HTTP API, no file parsing, no auth. IEx functions only.

## Data Model

### Documents Table

```elixir
defmodule Arcana.Document do
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "arcana_documents" do
    field :content, :string              # extracted text
    field :content_type, :string         # "text/plain", "application/pdf"
    field :source_id, :string            # opaque ID from host app
    field :file_path, :string            # path to original file
    field :metadata, :map, default: %{}
    field :status, Ecto.Enum,
          values: [:pending, :processing, :completed, :failed]
    field :error, :string
    field :chunk_count, :integer, default: 0

    has_many :chunks, Arcana.Chunk
    timestamps()
  end
end
```

### Chunks Table

```elixir
defmodule Arcana.Chunk do
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "arcana_chunks" do
    field :text, :string
    field :embedding, Pgvector.Ecto.Vector  # 384 dims
    field :chunk_index, :integer
    field :token_count, :integer
    field :metadata, :map, default: %{}

    belongs_to :document, Arcana.Document
    timestamps()
  end
end
```

### Migration

```elixir
execute "CREATE EXTENSION IF NOT EXISTS vector"

create table(:arcana_documents, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :content, :text
  add :content_type, :string, default: "text/plain"
  add :source_id, :string
  add :file_path, :string
  add :metadata, :map, default: %{}
  add :status, :string, default: "pending"
  add :error, :text
  add :chunk_count, :integer, default: 0
  timestamps()
end

create table(:arcana_chunks, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :text, :text, null: false
  add :embedding, :vector, size: 384, null: false
  add :chunk_index, :integer, default: 0
  add :token_count, :integer
  add :metadata, :map, default: %{}
  add :document_id, references(:arcana_documents, type: :binary_id, on_delete: :delete_all)
  timestamps()
end

create index(:arcana_chunks, [:document_id])
create index(:arcana_documents, [:source_id])
execute "CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks USING hnsw (embedding vector_cosine_ops)"
```

## Components

### Arcana (Main Supervisor)

Entry point. Starts the embedding server. Configured with host app's Repo.

```elixir
defmodule Arcana do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    Application.put_env(:arcana, :repo, repo)

    children = [
      Arcana.Embeddings.Serving
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Public API
  def ingest(text, opts \\ [])
  def search(query, opts \\ [])
  def delete(document_id)
end
```

### Arcana.Embeddings.Serving

Nx.Serving wrapping Bumblebee for bge-small-en-v1.5 (384 dimensions).

```elixir
defmodule Arcana.Embeddings.Serving do
  def child_spec(_opts)  # Returns Nx.Serving child spec
  def embed(text)        # Single text -> [float]
  def embed_batch(texts) # List of texts -> [[float]]
end
```

### Arcana.Chunker

Recursive character splitting with overlap.

```elixir
defmodule Arcana.Chunker do
  @default_chunk_size 1024
  @default_chunk_overlap 200

  def chunk(text, opts \\ [])
  # Returns [%{text: String.t(), chunk_index: integer(), token_count: integer()}]
end
```

### Arcana.Search

Vector similarity search using pgvector.

```elixir
defmodule Arcana.Search do
  def search(query_embedding, opts \\ [])
  # Options: limit, source_id, threshold
  # Returns [%{chunk: Chunk.t(), score: float()}]
end
```

## Infrastructure

### Docker Compose (for development)

```yaml
services:
  postgres:
    image: pgvector/pgvector:pg16
    ports:
      - "5432:5432"
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: arcana_dev
```

### mix arcana.install

Generates migration file in host app's priv/repo/migrations.

## Future Phases (Not in Scope)

- Phoenix API / ArcanaWeb.Router
- File parsing (PDF, DOCX)
- Async processing with Oban
- Hybrid search (vector + full-text)
- RAG with LLM providers
- Collections
- Multi-tenancy
