defmodule ArcanaWeb.SearchLive do
  @moduledoc """
  LiveView for searching documents in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(search_results: [], search_query: "")
     |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: load_collections(repo))
    |> assign(source_ids: load_source_ids(repo))
  end

  @impl true
  def handle_event("search", params, socket) do
    repo = socket.assigns.repo
    query = params["query"] || ""
    limit = parse_int(params["limit"], 10)
    threshold = parse_float(params["threshold"], 0.0)
    source_id = if params["source_id"] in [nil, ""], do: nil, else: params["source_id"]
    collection = if params["collection"] in [nil, ""], do: nil, else: params["collection"]
    mode = parse_mode(params["mode"])

    results =
      if query != "" do
        opts = [repo: repo, limit: limit, threshold: threshold, mode: mode]
        opts = if source_id, do: Keyword.put(opts, :source_id, source_id), else: opts
        opts = if collection, do: Keyword.put(opts, :collection, collection), else: opts
        Arcana.search(query, opts)
      else
        []
      end

    {:noreply, assign(socket, search_results: results, search_query: query)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:search}>
      <div class="arcana-search">
        <h2>Search</h2>

        <form id="search-form" phx-submit="search" class="arcana-search-form">
          <div class="arcana-search-inputs">
            <input type="text" name="query" placeholder="Enter search query..." value={@search_query} />

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

              <label>
                Collection
                <select name="collection">
                  <option value="">All collections</option>
                  <%= for collection <- @collections do %>
                    <option value={collection.name}><%= collection.name %></option>
                  <% end %>
                </select>
              </label>
            </div>
          </div>

          <button type="submit">Search</button>
        </form>

        <%= if Enum.empty?(@search_results) and @search_query != "" do %>
          <p class="arcana-empty">No results found for "<%= @search_query %>"</p>
        <% end %>

        <%= if not Enum.empty?(@search_results) do %>
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
              <%= for result <- @search_results do %>
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
    </.dashboard_layout>
    """
  end
end
