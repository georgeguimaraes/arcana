# Dashboard

A web UI for managing documents and testing search.

## Setup

Add the dashboard route to your router:

```elixir
# lib/my_app_web/router.ex
import ArcanaWeb.Router

scope "/" do
  pipe_through :browser

  arcana_dashboard "/arcana"
end
```

Visit `http://localhost:4000/arcana` to access the dashboard.

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

## Features

### Documents Tab

- **View documents** - Browse all ingested documents
- **View chunks** - See how documents are chunked
- **Ingest text** - Paste content directly
- **Upload files** - Upload `.txt`, `.md`, or `.pdf` files
- **Manage collections** - Organize documents into collections
- **Filter by collection** - View documents from specific collections

### Search Tab

- **Test queries** - Try searches against your documents
- **View results** - See retrieved chunks with similarity scores
- **Compare modes** - Test semantic, full-text, and hybrid search

### Evaluation Tab

- **View test cases** - See questions and their relevant chunks
- **Run evaluations** - Execute evaluation runs
- **View metrics** - See MRR, Precision, Recall scores
- **Compare runs** - Track changes over time

### Info Tab

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
