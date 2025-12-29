defmodule ArcanaWeb.SearchLive do
  @moduledoc """
  LiveView for searching documents in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  alias Arcana.Document

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       search_results: [],
       search_query: "",
       expanded_result_id: nil,
       viewing_document: nil
     )
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
    query = params["query"] || ""
    results = run_search(query, params, socket.assigns.repo)
    {:noreply, assign(socket, search_results: results, search_query: query, expanded_result_id: nil)}
  end

  def handle_event("toggle_result", %{"id" => id}, socket) do
    current = socket.assigns.expanded_result_id
    new_id = if current == id, do: nil, else: id
    {:noreply, assign(socket, expanded_result_id: new_id)}
  end

  def handle_event("view_search_document", %{"id" => id}, socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    document = repo.get(Document, id)

    chunks =
      repo.all(
        from(c in Arcana.Chunk,
          where: c.document_id == ^id,
          order_by: c.chunk_index
        )
      )

    {:noreply, assign(socket, viewing_document: %{document: document, chunks: chunks})}
  end

  def handle_event("close_search_document", _params, socket) do
    {:noreply, assign(socket, viewing_document: nil)}
  end

  defp run_search("", _params, _repo), do: []

  defp run_search(query, params, repo) do
    params
    |> build_search_opts(repo)
    |> then(&Arcana.search(query, &1))
  end

  defp build_search_opts(params, repo) do
    [
      repo: repo,
      limit: parse_int(params["limit"], 10),
      threshold: parse_float(params["threshold"], 0.0),
      mode: parse_mode(params["mode"])
    ]
    |> add_source_id_opt(params["source_id"])
    |> add_collection_opt(normalize_collections(params["collections"]))
  end

  defp add_source_id_opt(opts, nil), do: opts
  defp add_source_id_opt(opts, ""), do: opts
  defp add_source_id_opt(opts, source_id), do: Keyword.put(opts, :source_id, source_id)

  defp add_collection_opt(opts, []), do: opts
  defp add_collection_opt(opts, [single]), do: Keyword.put(opts, :collection, single)
  defp add_collection_opt(opts, multiple), do: Keyword.put(opts, :collection, multiple)

  defp normalize_collections(nil), do: []
  defp normalize_collections(collections) when is_list(collections), do: Enum.filter(collections, &(&1 != ""))
  defp normalize_collections(collection), do: [collection]

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:search}>
      <div class="arcana-search">
        <%= if @viewing_document do %>
          <.search_document_detail viewing={@viewing_document} />
        <% else %>
          <h2>Search</h2>
          <p class="arcana-tab-description">
            Perform vector similarity search to retrieve relevant document chunks from your knowledge base.
          </p>

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
              </div>

              <div class="arcana-ask-collections">
                <label>Collections</label>
                <div class="arcana-collection-checkboxes">
                  <%= for collection <- @collections do %>
                    <label class="arcana-collection-check">
                      <input type="checkbox" name="collections[]" value={collection.name} />
                      <span><%= collection.name %></span>
                    </label>
                  <% end %>
                </div>
                <small class="arcana-collection-hint">Select none for all collections</small>
              </div>
            </div>

            <button type="submit">Search</button>
          </form>

          <%= if Enum.empty?(@search_results) and @search_query != "" do %>
            <p class="arcana-empty">No results found for "<%= @search_query %>"</p>
          <% end %>

          <%= if not Enum.empty?(@search_results) do %>
            <div class="arcana-search-results">
              <%= for result <- @search_results do %>
                <div class="arcana-search-result">
                  <div class="arcana-result-header">
                    <div class="arcana-result-score">
                      <span class="score-value"><%= Float.round(result.score, 4) %></span>
                    </div>
                    <div class="arcana-result-meta">
                      <code><%= result.document_id %></code>
                      <span class="arcana-chunk-badge">Chunk <%= result.chunk_index %></span>
                    </div>
                    <div class="arcana-result-actions">
                      <button
                        class="arcana-result-btn"
                        phx-click="toggle_result"
                        phx-value-id={result.id}
                      >
                        <%= if @expanded_result_id == result.id, do: "Collapse", else: "Expand" %>
                      </button>
                      <button
                        class="arcana-result-btn arcana-result-btn-primary"
                        phx-click="view_search_document"
                        phx-value-id={result.document_id}
                      >
                        View Doc
                      </button>
                    </div>
                  </div>
                  <div class={"arcana-result-text #{if @expanded_result_id == result.id, do: "expanded", else: ""}"}>
                    <%= if @expanded_result_id == result.id do %>
                      <%= result.text %>
                    <% else %>
                      <%= String.slice(result.text, 0, 200) %><%= if String.length(result.text) > 200, do: "...", else: "" %>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp search_document_detail(assigns) do
    ~H"""
    <div class="arcana-doc-detail">
      <div class="arcana-doc-header">
        <h2>Document Details</h2>
        <button class="arcana-close-btn" phx-click="close_search_document">← Back to search</button>
      </div>

      <div class="arcana-doc-info">
        <div class="arcana-doc-field">
          <label>ID</label>
          <code><%= @viewing.document.id %></code>
        </div>
        <div class="arcana-doc-field">
          <label>Source</label>
          <span><%= @viewing.document.source_id || "-" %></span>
        </div>
        <div class="arcana-doc-field">
          <label>Metadata</label>
          <span><%= format_metadata(@viewing.document.metadata) %></span>
        </div>
        <div class="arcana-doc-field">
          <label>Created</label>
          <span><%= @viewing.document.inserted_at %></span>
        </div>
      </div>

      <div class="arcana-doc-section">
        <h3>Full Content</h3>
        <pre class="arcana-doc-content"><%= @viewing.document.content %></pre>
      </div>

      <div class="arcana-doc-section">
        <h3>Chunks (<%= length(@viewing.chunks) %>)</h3>
        <div class="arcana-chunks-list">
          <%= for chunk <- @viewing.chunks do %>
            <div class="arcana-chunk">
              <div class="arcana-chunk-header">
                <span class="arcana-chunk-index">Chunk <%= chunk.chunk_index %></span>
                <span class="arcana-chunk-tokens"><%= chunk.token_count %> tokens</span>
              </div>
              <pre class="arcana-chunk-text"><%= chunk.text %></pre>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
