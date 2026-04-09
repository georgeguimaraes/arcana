# Dashboard

A web UI for managing documents and testing search. The dashboard consists of multiple pages accessible via sidebar navigation.

## Setup

### 1. Add TaskSupervisor to your supervision tree

The dashboard requires `Arcana.TaskSupervisor` for async operations (Ask, Maintenance):

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  Arcana.TaskSupervisor,  # Required for dashboard
  # ...
]
```

### 2. Add the dashboard route

```elixir
# lib/my_app_web/router.ex
import ArcanaWeb.Router

scope "/" do
  pipe_through :browser

  arcana_dashboard "/arcana"
end
```

Visit `http://localhost:4000/arcana` to access the dashboard (redirects to Documents page).

### 3. Optional: Markdown rendering for answers

Add `mdex` to your `mix.exs` if you want the **Ask** page to render
LLM answers as Markdown (paragraphs, bullet lists, bold, inline code,
etc.) instead of plain text:

```elixir
{:mdex, "~> 0.12"}
```

[MDEx](https://github.com/leandrocp/mdex) is a fast CommonMark + GitHub
Flavored Markdown parser built on the comrak Rust NIF, with built-in
HTML sanitization via ammonia. Arcana enables sanitization
unconditionally for the dashboard so any raw HTML the LLM emits
gets stripped before render. The dep is installed as a precompiled
NIF via `rustler_precompiled`, so you don't need a Rust toolchain
on your machine.

Without `mdex`, the Ask page falls back to plain-text rendering
and the page still works, but bullet markers and `**bold**` just
appear literally instead of being formatted.

## Options

```elixir
arcana_dashboard "/arcana",
  repo: MyApp.Repo,                    # Override repo
  on_mount: [MyAppWeb.Auth],           # Add authentication
  live_socket_path: "/live"            # Custom LiveView socket path
```

### Authentication

Protect the dashboard with your existing authentication:

```elixir
arcana_dashboard "/arcana",
  on_mount: [MyAppWeb.RequireAdmin]
```

## Pages

### Documents (`/arcana/documents`)

- **View documents** - Browse all ingested documents with pagination
- **View chunks** - See how documents are chunked
- **Ingest text** - Paste content directly with format selection
- **Upload files** - Upload `.txt`, `.md`, or `.pdf` files
- **Filter by collection** - View documents from specific collections

### Ask (`/arcana/ask`)

Three sub-tabs that map onto Arcana's three retrieval surfaces. The
URL preserves your selection (`/arcana/ask/advanced`,
`/arcana/ask/pipeline`, `/arcana/ask/loop`).

- **Advanced** (`Arcana.ask/2`): one call with sensible defaults.
  Hybrid search, optional graph fusion, cross-encoder reranking,
  LLM answer. Use this when you want the library to make the
  decisions.
- **Pipeline** (`Arcana.Pipeline`): Modular RAG. Compose the steps
  yourself via toggles (gate, rewrite, expand, decompose, search,
  reason, rerank, answer, ground). Each step has its own checkbox.
- **Loop** (`Arcana.Loop`): Agentic RAG. The controller LLM picks
  tools each turn and decides when to commit. The settings panel
  shows which LLMs are configured for each role (controller,
  answerer, fallback synthesizer).

All three sub-tabs share:

- **Collection selection** - pick which collections to search (or
  for Pipeline, let the LLM auto-select)
- **Live tracing** - while a run is in flight, the retrieval steps
  appear as a vertical timeline as they happen, color-coded by tool
  type. Pipeline shows steps with running/done states and durations;
  Loop shows tool calls with arguments and chunk counts. The trace
  is powered by the `[:arcana, :pipeline, :*, :*]`,
  `[:arcana, :loop, :tool_call]`, and related telemetry events
- **Markdown answers** - when `mdex` is in your deps (see Setup
  step 3), answers are rendered as formatted Markdown with safe HTML
  sanitization. Without it, answers fall back to plain text
- **Grounding** - if Hallmark is configured, the dashboard renders
  hallucinated spans in red and faithful spans in green, with
  per-chunk attribution on hover

### Search (`/arcana/search`)

- **Test queries** - Try searches against your documents
- **View results** - See retrieved chunks with similarity scores and expandable details
- **Compare modes** - Test semantic, full-text, and hybrid search
- **Filter by collection** - Search within specific collections

### Collections (`/arcana/collections`)

- **View collections** - Browse all collections with document counts
- **Create collections** - Add new collections with descriptions
- **Edit collections** - Update collection descriptions
- **Delete collections** - Remove empty collections

### Evaluation (`/arcana/evaluation`)

- **View test cases** - See questions and their relevant chunks
- **Run evaluations** - Execute evaluation runs
- **View metrics** - See MRR, Precision, Recall scores
- **Compare runs** - Track changes over time

### Maintenance (`/arcana/maintenance`)

- **Rebuild embeddings** - Re-embed all chunks (useful after model changes)
- **Orphan cleanup** - Find and remove chunks without parent documents
- **Database operations** - Maintenance tasks for the vector store

### Info (`/arcana/info`)

- **Configuration** - View current Arcana settings
- **Embedding model** - See which model is in use
- **Statistics** - Document and chunk counts

## Deployment

The dashboard uses Phoenix LiveView. Ensure your production configuration includes:

```elixir
# config/runtime.exs
config :my_app, MyAppWeb.Endpoint,
  url: [host: "example.com", port: 443],
  check_origin: ["//example.com"]
```

### Assets

Dashboard assets (CSS, JS) are served inline - no build step required.

## Security Considerations

The dashboard provides full access to your Arcana data:

1. **Always add authentication** in production
2. **Restrict to admin users** who need access
3. **Consider IP allowlisting** for sensitive deployments

```elixir
# Example: Admin-only access
defmodule MyAppWeb.RequireAdmin do
  import Phoenix.LiveView

  def on_mount(:default, _params, session, socket) do
    case session["current_user"] do
      %{admin: true} -> {:cont, socket}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end
end
```
