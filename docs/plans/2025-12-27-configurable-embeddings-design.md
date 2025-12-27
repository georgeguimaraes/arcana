# Configurable Embeddings Design

## Overview

Add configurable embedding providers to Arcana, allowing users to choose between local Bumblebee models, OpenAI embeddings, or custom functions.

## Decisions

- **Single dimension per deployment** - Mixing dimensions corrupts the index. Changing models requires re-embedding.
- **Startup configuration** - Embeddings configured once in config, not per-operation. Prevents accidental mismatches.
- **Auto-detect dimensions** - Query model at startup, no manual dimension config needed.
- **Separate migration and re-embed tasks** - Follows Ecto conventions, gives user control.

## Configuration API

```elixir
# config/config.exs or config/runtime.exs

# Default: Local Bumblebee with bge-small-en-v1.5 (384 dims)
config :arcana, embedding: :local

# Local with different HuggingFace model
config :arcana, embedding: {:local, model: "BAAI/bge-large-en-v1.5"}

# OpenAI via Req.LLM
config :arcana, embedding: {:openai, model: "text-embedding-3-small"}

# Custom function (escape hatch for any provider)
config :arcana, embedding: {:custom, fn texts -> YourModule.embed(texts) end}
```

**Behavior:**
- At startup, Arcana reads config and initializes the appropriate embedder
- Dimensions are auto-detected by embedding a test string
- If config is missing, defaults to `:local` (backward compatible)
- For `:local`, starts Nx.Serving. For `:openai`/`:custom`, no GenServer needed.

**Validation:**
- Startup fails fast if model can't be loaded or API unreachable
- Logs detected dimensions: `[info] Arcana embedding: openai:text-embedding-3-small (1536 dims)`

## Embedding Protocol

```elixir
defprotocol Arcana.Embedding do
  @doc "Embed a single text, returns list of floats"
  @spec embed(t, String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(embedder, text)

  @doc "Embed multiple texts in batch"
  @spec embed_batch(t, [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(embedder, texts)

  @doc "Returns the embedding dimensions"
  @spec dimensions(t) :: pos_integer()
  def dimensions(embedder)
end
```

**Implementations:**

| Struct | Provider |
|--------|----------|
| `Arcana.Embedding.Local` | Bumblebee/Nx.Serving |
| `Arcana.Embedding.OpenAI` | Req.LLM |
| `Function` | Custom user function |

At startup, config is parsed into a struct that implements the protocol. Stored in application env or persistent_term for fast access.

## Mix Tasks

### `mix arcana.gen.embedding_migration`

Generates a migration to update vector column dimensions:

```bash
$ mix arcana.gen.embedding_migration

Detected embedding: openai:text-embedding-3-small (1536 dims)
Current schema: 384 dims

Generated: priv/repo/migrations/20241227_update_embedding_dimensions.exs
```

Migration content:
```elixir
def change do
  drop index(:arcana_chunks, [:embedding], using: :hnsw)

  alter table(:arcana_chunks) do
    modify :embedding, :vector, size: 1536
  end

  create index(:arcana_chunks, [:embedding], using: :hnsw, ...)
end
```

### `mix arcana.reembed`

Re-embeds all documents with progress:

```bash
$ mix arcana.reembed --batch-size 50

Re-embedding 1,234 chunks...
[============================] 100% (1,234/1,234)
Done in 2m 34s
```

### Production Usage

Mix tasks wrap `Arcana.Maintenance` module for production use:

```elixir
# Remote IEx
iex> Arcana.Maintenance.reembed(MyApp.Repo, batch_size: 100)

# Release command
bin/my_app eval "Arcana.Maintenance.reembed(MyApp.Repo)"
```

Dashboard also gets a re-embed button with progress display.

## Files to Change

| Component | Change |
|-----------|--------|
| `lib/arcana/embedding.ex` | New protocol definition |
| `lib/arcana/embedding/local.ex` | Bumblebee implementation (refactor from Serving) |
| `lib/arcana/embedding/openai.ex` | OpenAI via Req.LLM |
| `lib/arcana/embedding/function.ex` | Custom function impl |
| `lib/arcana/maintenance.ex` | `reembed/2` function |
| `lib/mix/tasks/arcana.gen.embedding_migration.ex` | Migration generator |
| `lib/mix/tasks/arcana.reembed.ex` | Re-embed task |
| `lib/arcana.ex` | Update `ingest/2` and `search/2` to use protocol |
| `lib/arcana_web/dashboard_live.ex` | Add re-embed button |
| `README.md` | Document embedding config |
| `guides/llm-integration.md` | Add embedding section |

## Backward Compatibility

No config = `:local` with `bge-small-en-v1.5` (current behavior). Existing deployments continue working unchanged.
