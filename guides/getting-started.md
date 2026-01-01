# Getting Started with Arcana 🔮📚

Arcana is a RAG (Retrieval Augmented Generation) library for Elixir that lets you build AI-powered search and question-answering into your Phoenix applications.

## Installation

**With Igniter (recommended):**

```bash
mix igniter.install arcana
mix ecto.migrate
```

This adds the dependency, creates migrations, configures your repo, and sets up the dashboard route.

**Without Igniter:**

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"}
  ]
end
```

```bash
mix deps.get
mix arcana.install
mix ecto.migrate
```

## Embedding Configuration

Arcana uses local embeddings by default via Bumblebee. No API keys needed.

```elixir
# config/config.exs

# Default - BGE Small (384 dimensions, 133MB)
config :arcana, embedder: :local

# Use a different model
config :arcana, embedder: {:local, model: "BAAI/bge-base-en-v1.5"}
```

Add the embedding model to your supervision tree:

```elixir
# application.ex
children = [
  MyApp.Repo,
  {Arcana.Embedder.Local, model: "BAAI/bge-small-en-v1.5"},
  # ...
]
```

### Available Models

| Model | Dimensions | Size | Use Case |
|-------|------------|------|----------|
| `BAAI/bge-small-en-v1.5` | 384 | 133MB | Default, good balance |
| `BAAI/bge-base-en-v1.5` | 768 | 438MB | Better accuracy |
| `BAAI/bge-large-en-v1.5` | 1024 | 1.3GB | Best accuracy |
| `intfloat/e5-small-v2` | 384 | 133MB | Alternative to BGE |
| `thenlper/gte-small` | 384 | 67MB | Smallest, fastest |
| `sentence-transformers/all-MiniLM-L6-v2` | 384 | 91MB | Lightweight |

### Changing Embedding Models

When switching to a model with different dimensions, you need to resize the vector column:

```bash
# 1. Update your config to use the new model
# 2. Generate a migration to resize the vector column
mix arcana.gen.embedding_migration

# 3. Run the migration
mix ecto.migrate

# 4. Re-embed all documents with the new model
mix arcana.reembed
```

For OpenAI embeddings or custom providers, see the [LLM Integration](llm-integration.md) guide.

## Chunking Configuration

Arcana uses the default text chunker which splits documents into overlapping chunks:

```elixir
# config/config.exs

# Default - 450 tokens with 50 token overlap
config :arcana, chunker: :default

# Custom chunk sizes
config :arcana, chunker: {:default, chunk_size: 512, chunk_overlap: 100}
```

### Available Options

| Option | Default | Description |
|--------|---------|-------------|
| `:chunk_size` | 450 | Maximum tokens per chunk |
| `:chunk_overlap` | 50 | Overlapping tokens between chunks |
| `:format` | `:plaintext` | Text format (`:plaintext`, `:markdown`, `:elixir`) |
| `:size_unit` | `:tokens` | How to measure size (`:tokens`, `:characters`) |

### Custom Chunkers

For semantic chunking or domain-specific splitting, implement the `Arcana.Chunker` behaviour:

```elixir
defmodule MyApp.SemanticChunker do
  @behaviour Arcana.Chunker

  @impl true
  def chunk(text, opts) do
    # Split on semantic boundaries (paragraphs, sections, etc.)
    text
    |> split_semantically()
    |> Enum.with_index()
    |> Enum.map(fn {text, index} ->
      %{text: text, chunk_index: index, token_count: estimate_tokens(text)}
    end)
  end
end

# Configure globally
config :arcana, chunker: MyApp.SemanticChunker

# Or per-ingest
Arcana.ingest(text, repo: MyApp.Repo, chunker: MyApp.SemanticChunker)
```

## Basic Usage

### Ingesting Documents

```elixir
# Ingest text content
{:ok, document} = Arcana.ingest("Your content here", repo: MyApp.Repo)

# With metadata
{:ok, document} = Arcana.ingest(
  "Article about Elixir",
  repo: MyApp.Repo,
  metadata: %{"author" => "Jane", "category" => "programming"}
)

# With a source ID for grouping
{:ok, document} = Arcana.ingest(
  "Chapter 1 content",
  repo: MyApp.Repo,
  source_id: "book-123"
)

# Ingest from file (supports .txt, .md, .pdf)
{:ok, document} = Arcana.ingest_file("path/to/document.pdf", repo: MyApp.Repo)

# Organize documents into collections
{:ok, document} = Arcana.ingest(
  "Product documentation",
  repo: MyApp.Repo,
  collection: "products"
)

# With collection description (helps Agent.select/2 route to the right collection)
{:ok, document} = Arcana.ingest(
  "API reference",
  repo: MyApp.Repo,
  collection: %{name: "api", description: "REST API endpoints and parameters"}
)
```

> **Note:** PDF support requires `pdftotext` from the Poppler library. Install with:
> - macOS: `brew install poppler`
> - Ubuntu/Debian: `apt-get install poppler-utils`
> - Check availability: `Arcana.Parser.pdf_support_available?()`

### Searching

```elixir
# Semantic search (default)
{:ok, results} = Arcana.search("functional programming", repo: MyApp.Repo)

# Full-text search
{:ok, results} = Arcana.search("Elixir", repo: MyApp.Repo, mode: :fulltext)

# Hybrid search (combines semantic + fulltext)
{:ok, results} = Arcana.search("Elixir patterns", repo: MyApp.Repo, mode: :hybrid)

# Hybrid with custom weights (pgvector backend)
{:ok, results} = Arcana.search("Elixir patterns",
  repo: MyApp.Repo,
  mode: :hybrid,
  semantic_weight: 0.7,  # Weight for semantic similarity
  fulltext_weight: 0.3   # Weight for keyword matching
)

# With filters
{:ok, results} = Arcana.search("query",
  repo: MyApp.Repo,
  limit: 5,
  threshold: 0.7,
  source_id: "book-123",
  collection: "products"  # Filter by collection
)
```

### Question Answering

Use `Arcana.ask/2` to combine search with an LLM for answers:

```elixir
llm_fn = fn prompt, context ->
  # Call your LLM API here
  {:ok, "Generated answer based on context"}
end

{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: llm_fn,
  limit: 5
)
```

See the [LLM Integration](llm-integration.md) guide for production-ready LLM integration.

## Agentic RAG Pipeline

For more control over the RAG process, use the Agent pipeline:

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, "LLM response"} end

ctx =
  Agent.new("Compare Elixir and Erlang", repo: MyApp.Repo, llm: llm)
  |> Agent.select(collections: ["elixir-docs", "erlang-docs"])
  |> Agent.expand()
  |> Agent.search()
  |> Agent.answer()

ctx.answer
```

### Pipeline Steps

| Step | Purpose |
|------|---------|
| `new/2` | Initialize with question, repo, and LLM |
| `select/2` | Choose which collections to search |
| `expand/2` | Add synonyms to improve retrieval |
| `decompose/2` | Split complex questions into parts |
| `search/2` | Execute search (with optional self-correction) |
| `rerank/2` | Re-score and filter chunks by relevance |
| `answer/2` | Generate final answer |

### Expand vs. Decompose

Use **`expand/2`** when queries contain abbreviations, jargon, or domain-specific terms:

```elixir
# Before expand: "ML models"
# After expand: "ML machine learning artificial intelligence models algorithms"

ctx
|> Agent.expand()
|> Agent.search()
```

Use **`decompose/2`** when questions have multiple parts:

```elixir
# Before decompose: "What is X and how does it compare to Y?"
# After decompose: ["What is X?", "How does it compare to Y?"]

ctx
|> Agent.decompose()
|> Agent.search()  # Searches each sub-question
```

You can combine both:

```elixir
ctx
|> Agent.expand()      # Adds synonyms to the original question
|> Agent.decompose()   # Splits into sub-questions
|> Agent.search()      # Searches each expanded sub-question
```

### Self-Correcting Search

Enable automatic query refinement when results are insufficient:

```elixir
ctx
|> Agent.search(self_correct: true, max_iterations: 3)
```

The agent will:
1. Execute the search
2. Ask the LLM if results are sufficient
3. If not, rewrite the query and retry
4. Repeat until sufficient or max iterations reached

### Re-ranking

Improve result quality by re-scoring chunks after retrieval:

```elixir
ctx
|> Agent.search()
|> Agent.rerank(threshold: 7)  # Keep chunks scoring 7+/10
|> Agent.answer()
```

The LLM scores each chunk's relevance to the question. Chunks below the threshold are filtered out, and remaining chunks are sorted by score.

For custom re-ranking logic (e.g., cross-encoder models):

```elixir
# Custom reranker module
defmodule MyApp.CrossEncoderReranker do
  @behaviour Arcana.Agent.Reranker

  @impl true
  def rerank(question, chunks, _opts) do
    # Your scoring logic here
    {:ok, scored_chunks}
  end
end

ctx |> Agent.rerank(reranker: MyApp.CrossEncoderReranker)
```

## Query Rewriting

Improve search results by rewriting queries before searching:

```elixir
alias Arcana.Rewriters

# Create a rewriter with your LLM
rewriter = Rewriters.expand(llm: fn prompt ->
  # Call LLM to expand the query
  {:ok, "expanded query with synonyms"}
end)

# Use it with search
results = Arcana.search("ML",
  repo: MyApp.Repo,
  rewriter: rewriter
)
```

## Dashboard UI

Arcana includes a LiveView dashboard for managing documents:

```elixir
# In your router
import ArcanaWeb.Router

scope "/admin", MyAppWeb do
  pipe_through [:browser, :admin]
  arcana_dashboard("/arcana", repo: MyApp.Repo)
end
```

## Telemetry

Arcana emits telemetry events for all operations. You can attach handlers to observe performance and usage:

```elixir
# In your application startup
:telemetry.attach_many(
  "my-arcana-handler",
  [
    [:arcana, :ingest, :stop],
    [:arcana, :search, :stop],
    [:arcana, :ask, :stop]
  ],
  fn event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("#{inspect(event)} completed in #{duration_ms}ms")
  end,
  nil
)
```

Events follow the `:telemetry.span/3` convention with `:start`, `:stop`, and `:exception` suffixes. See `Arcana.Telemetry` for complete documentation.

## Next Steps

- [LLM Integration](llm-integration.md) - Connect Arcana to LLMs
- [Agentic RAG](agentic-rag.md) - Build sophisticated RAG pipelines
- [Re-ranking](reranking.md) - Improve retrieval quality
- [Search Algorithms](search-algorithms.md) - Hybrid search modes
- [Evaluation](evaluation.md) - Measure retrieval quality
- [Dashboard](dashboard.md) - Web UI setup
