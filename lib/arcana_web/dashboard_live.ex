defmodule ArcanaWeb.DashboardLive do
  @moduledoc """
  LiveView for the Arcana dashboard.

  Provides tabs for managing documents and searching.
  """
  use Phoenix.LiveView

  alias Arcana.Document

  @impl true
  def mount(_params, session, socket) do
    repo = session["repo"] || Arcana.TestRepo

    socket =
      socket
      |> assign(tab: :documents, repo: repo)
      |> assign(search_results: [], search_query: "")
      |> load_documents()
      |> load_source_ids()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("ingest", params, socket) do
    repo = socket.assigns.repo
    content = params["content"] || ""
    format = parse_format(params["format"])

    {:ok, _doc} = Arcana.ingest(content, repo: repo, format: format)
    {:noreply, load_documents(socket)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case Arcana.delete(id, repo: repo) do
      :ok ->
        {:noreply, load_documents(socket)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("search", params, socket) do
    repo = socket.assigns.repo
    query = params["query"] || ""
    limit = parse_int(params["limit"], 10)
    threshold = parse_float(params["threshold"], 0.0)
    source_id = if params["source_id"] in [nil, ""], do: nil, else: params["source_id"]
    mode = parse_mode(params["mode"])

    results =
      if query != "" do
        opts = [repo: repo, limit: limit, threshold: threshold, mode: mode]
        opts = if source_id, do: Keyword.put(opts, :source_id, source_id), else: opts
        Arcana.search(query, opts)
      else
        []
      end

    {:noreply, assign(socket, search_results: results, search_query: query)}
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_mode("semantic"), do: :semantic
  defp parse_mode("fulltext"), do: :fulltext
  defp parse_mode("hybrid"), do: :hybrid
  defp parse_mode(_), do: :semantic

  defp parse_format("plaintext"), do: :plaintext
  defp parse_format("markdown"), do: :markdown
  defp parse_format("elixir"), do: :elixir
  defp parse_format(_), do: :plaintext

  defp format_metadata(nil), do: "-"
  defp format_metadata(metadata) when metadata == %{}, do: "-"

  defp format_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
  end

  defp load_documents(socket) do
    repo = socket.assigns.repo
    documents = repo.all(Document)
    assign(socket, documents: documents)
  end

  defp load_source_ids(socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    source_ids =
      repo.all(
        from(d in Document,
          where: not is_nil(d.source_id),
          distinct: d.source_id,
          select: d.source_id
        )
      )

    assign(socket, source_ids: source_ids)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .arcana-dashboard {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        max-width: 1200px;
        margin: 0 auto;
        padding: 1.5rem;
        color: #1f2937;
      }

      .arcana-tabs {
        display: flex;
        gap: 0.5rem;
        border-bottom: 2px solid #e5e7eb;
        margin-bottom: 1.5rem;
      }

      .arcana-tab {
        padding: 0.75rem 1.5rem;
        border: none;
        background: transparent;
        font-size: 1rem;
        font-weight: 500;
        color: #6b7280;
        cursor: pointer;
        border-bottom: 2px solid transparent;
        margin-bottom: -2px;
        transition: all 0.15s ease;
      }

      .arcana-tab:hover {
        color: #7c3aed;
      }

      .arcana-tab.active {
        color: #7c3aed;
        border-bottom-color: #7c3aed;
      }

      .arcana-dashboard h2 {
        font-size: 1.5rem;
        font-weight: 600;
        color: #111827;
        margin: 0 0 1rem 0;
      }

      .arcana-ingest-form,
      .arcana-search-form {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1.5rem;
      }

      .arcana-ingest-form textarea,
      .arcana-search-form input[type="text"] {
        width: 100%;
        padding: 0.75rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        margin-bottom: 0.75rem;
        box-sizing: border-box;
      }

      .arcana-ingest-form textarea:focus,
      .arcana-search-form input:focus,
      .arcana-search-form select:focus {
        outline: none;
        border-color: #7c3aed;
        box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
      }

      .arcana-search-options {
        display: flex;
        gap: 1rem;
        flex-wrap: wrap;
        margin-bottom: 0.75rem;
      }

      .arcana-search-options label {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
      }

      .arcana-search-options select,
      .arcana-search-options input[type="number"] {
        padding: 0.5rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        min-width: 100px;
      }

      .arcana-ingest-form button,
      .arcana-search-form button {
        background: #7c3aed;
        color: white;
        padding: 0.625rem 1.25rem;
        border: none;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        font-weight: 500;
        cursor: pointer;
        transition: background-color 0.15s ease;
      }

      .arcana-ingest-form button:hover,
      .arcana-search-form button:hover {
        background: #6d28d9;
      }

      .arcana-ingest-options {
        display: flex;
        gap: 1rem;
        margin-bottom: 0.75rem;
      }

      .arcana-ingest-options label {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
      }

      .arcana-ingest-options select {
        padding: 0.5rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        min-width: 120px;
      }

      .arcana-ingest-options select:focus {
        outline: none;
        border-color: #7c3aed;
        box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
      }

      .arcana-empty {
        color: #6b7280;
        font-style: italic;
        padding: 2rem;
        text-align: center;
        background: #f9fafb;
        border-radius: 0.5rem;
      }

      .arcana-documents-table,
      .arcana-results-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 0.875rem;
      }

      .arcana-documents-table th,
      .arcana-results-table th {
        text-align: left;
        padding: 0.75rem;
        background: #f3f4f6;
        border-bottom: 2px solid #e5e7eb;
        font-weight: 600;
        color: #374151;
      }

      .arcana-documents-table td,
      .arcana-results-table td {
        padding: 0.75rem;
        border-bottom: 1px solid #e5e7eb;
        vertical-align: top;
      }

      .arcana-documents-table tr:hover,
      .arcana-results-table tr:hover {
        background: #f9fafb;
      }

      .arcana-documents-table code,
      .arcana-results-table code {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
        font-size: 0.75rem;
        background: #ede9fe;
        color: #6d28d9;
        padding: 0.125rem 0.375rem;
        border-radius: 0.25rem;
      }

      .arcana-documents-table button {
        background: transparent;
        color: #dc2626;
        border: 1px solid #dc2626;
        padding: 0.375rem 0.75rem;
        border-radius: 0.25rem;
        font-size: 0.75rem;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .arcana-documents-table button:hover {
        background: #dc2626;
        color: white;
      }

      .arcana-metadata {
        font-size: 0.75rem;
        color: #6b7280;
        max-width: 200px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
    </style>
    <div class="arcana-dashboard">
      <nav class="arcana-tabs">
        <button
          data-tab="documents"
          class={"arcana-tab #{if @tab == :documents, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="documents"
        >
          Documents
        </button>
        <button
          data-tab="search"
          class={"arcana-tab #{if @tab == :search, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="search"
        >
          Search
        </button>
      </nav>

      <div class="arcana-content">
        <%= case @tab do %>
          <% :documents -> %>
            <.documents_tab documents={@documents} />
          <% :search -> %>
            <.search_tab results={@search_results} query={@search_query} source_ids={@source_ids} />
        <% end %>
      </div>
    </div>
    """
  end

  defp documents_tab(assigns) do
    ~H"""
    <div class="arcana-documents">
      <h2>Documents</h2>

      <form id="ingest-form" phx-submit="ingest" class="arcana-ingest-form">
        <textarea name="content" placeholder="Paste text to ingest..." rows="4"></textarea>
        <div class="arcana-ingest-options">
          <label>
            Format
            <select name="format">
              <option value="plaintext">Plaintext</option>
              <option value="markdown">Markdown</option>
              <option value="elixir">Elixir</option>
            </select>
          </label>
        </div>
        <button type="submit">Ingest</button>
      </form>

      <%= if Enum.empty?(@documents) do %>
        <p class="arcana-empty">No documents yet. Paste some text above to get started.</p>
      <% else %>
        <table class="arcana-documents-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Content</th>
              <th>Source</th>
              <th>Metadata</th>
              <th>Chunks</th>
              <th>Created</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for doc <- @documents do %>
              <tr>
                <td><code><%= doc.id %></code></td>
                <td><%= String.slice(doc.content || "", 0, 100) %>...</td>
                <td><%= doc.source_id || "-" %></td>
                <td class="arcana-metadata"><%= format_metadata(doc.metadata) %></td>
                <td><%= doc.chunk_count %></td>
                <td><%= doc.inserted_at %></td>
                <td>
                  <button
                    data-delete-doc={doc.id}
                    phx-click="delete"
                    phx-value-id={doc.id}
                  >
                    Delete
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp search_tab(assigns) do
    ~H"""
    <div class="arcana-search">
      <h2>Search</h2>

      <form id="search-form" phx-submit="search" class="arcana-search-form">
        <div class="arcana-search-inputs">
          <input type="text" name="query" placeholder="Enter search query..." value={@query} />

          <div class="arcana-search-options">
            <label>
              Mode
              <select name="mode">
                <option value="semantic">Semantic</option>
                <option value="fulltext">Full-text</option>
                <option value="hybrid">Hybrid</option>
              </select>
            </label>

            <label>
              Limit
              <select name="limit">
                <option value="5">5</option>
                <option value="10" selected>10</option>
                <option value="20">20</option>
                <option value="50">50</option>
              </select>
            </label>

            <label>
              Threshold
              <input type="number" name="threshold" min="0" max="1" step="0.1" value="0" />
            </label>

            <label>
              Source
              <select name="source_id">
                <option value="">All sources</option>
                <%= for source_id <- @source_ids do %>
                  <option value={source_id}><%= source_id %></option>
                <% end %>
              </select>
            </label>
          </div>
        </div>

        <button type="submit">Search</button>
      </form>

      <%= if Enum.empty?(@results) and @query != "" do %>
        <p class="arcana-empty">No results found for "<%= @query %>"</p>
      <% end %>

      <%= if not Enum.empty?(@results) do %>
        <table class="arcana-results-table">
          <thead>
            <tr>
              <th>Score</th>
              <th>Text</th>
              <th>Document ID</th>
              <th>Chunk Index</th>
            </tr>
          </thead>
          <tbody>
            <%= for result <- @results do %>
              <tr>
                <td><%= Float.round(result.score, 4) %></td>
                <td><%= String.slice(result.text, 0, 200) %>...</td>
                <td><code><%= result.document_id %></code></td>
                <td><%= result.chunk_index %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end
end
