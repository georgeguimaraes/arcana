# Getting Started with Arcana

Arcana is a RAG (Retrieval Augmented Generation) library for Elixir that lets you build AI-powered search and question-answering into your Phoenix applications.

## Installation

Add Arcana to your dependencies:

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
```

The installer will:
- Add pgvector extension to your database
- Generate the documents and chunks migrations
- Configure the embedding model

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
```

### Searching

```elixir
# Semantic search (default)
results = Arcana.search("functional programming", repo: MyApp.Repo)

# Full-text search
results = Arcana.search("Elixir", repo: MyApp.Repo, mode: :fulltext)

# Hybrid search (combines semantic + fulltext with RRF)
results = Arcana.search("Elixir patterns", repo: MyApp.Repo, mode: :hybrid)

# With filters
results = Arcana.search("query",
  repo: MyApp.Repo,
  limit: 5,
  threshold: 0.7,
  source_id: "book-123"
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

See the [LangChain Integration](langchain-integration.md) guide for production-ready LLM integration.

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

## Next Steps

- [LangChain Integration](langchain-integration.md) - Connect Arcana to LLMs
- API Reference - Full documentation of all modules
