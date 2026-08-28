# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Only
# ArcanaWeb.TaskSupervisor is phoenix-free and stays available.

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.SearchLive do
    @moduledoc """
    LiveView for searching documents in Arcana.
    """
    use Phoenix.LiveView

    import ArcanaWeb.DashboardComponents

    alias Arcana.{CollectionScope, Document}

    import Ecto.Query

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
         viewing_document: nil,
         stats: nil,
         collections: [],
         source_ids: []
       )}
    end

    @impl true
    def handle_params(_params, _uri, socket) do
      {:noreply, load_data(socket)}
    end

    defp load_data(socket) do
      repo = socket.assigns.repo
      allowed = socket.assigns.allowed_collections

      socket
      |> assign(stats: load_stats(repo, allowed))
      |> assign(collections: load_collections(repo, allowed))
      |> assign(source_ids: load_source_ids(repo, allowed))
    end

    @impl true
    def handle_event("search", params, socket) do
      query = params["query"] || ""
      results = run_search(query, params, socket.assigns.repo, socket.assigns.allowed_collections)

      {:noreply,
       assign(socket, search_results: results, search_query: query, expanded_result_id: nil)}
    end

    def handle_event("toggle_result", %{"id" => id}, socket) do
      current = socket.assigns.expanded_result_id
      new_id = if current == id, do: nil, else: id
      {:noreply, assign(socket, expanded_result_id: new_id)}
    end

    # A forged id that isn't a UUID can't match a document, so it's rejected
    # before the query would raise an Ecto.Query.CastError on the cast.
    def handle_event("view_search_document", %{"id" => id}, socket) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> view_search_document(socket, uuid)
        :error -> {:noreply, socket}
      end
    end

    def handle_event("close_search_document", _params, socket) do
      {:noreply, assign(socket, viewing_document: nil)}
    end

    defp view_search_document(socket, id) do
      repo = socket.assigns.repo

      case scoped_published_document(repo, id, socket.assigns.allowed_collections) do
        {:ok, document} ->
          chunks = scoped_published_chunks(repo, id, socket.assigns.allowed_collections)

          {:noreply, assign(socket, viewing_document: %{document: document, chunks: chunks})}

        _ ->
          {:noreply, socket}
      end
    end

    defp scoped_published_document(repo, id, allowed) do
      query =
        Document
        |> where([document], document.id == ^id and document.status == :completed)
        |> apply_document_scope(allowed)
        |> preload([:collection])

      case repo.one(query) do
        %Document{} = document -> {:ok, document}
        nil -> {:error, :not_found}
      end
    end

    defp scoped_published_chunks(repo, id, allowed) do
      Arcana.Chunk
      |> join(:inner, [chunk], document in assoc(chunk, :document))
      |> where(
        [chunk, document],
        chunk.document_id == ^id and document.status == :completed
      )
      |> apply_chunk_scope(allowed)
      |> order_by([chunk], chunk.chunk_index)
      |> repo.all()
    end

    defp apply_document_scope(query, allowed) do
      case CollectionScope.normalize!(allowed) do
        :all ->
          query

        {:only, []} ->
          where(query, [document], is_nil(document.id))

        {:only, names} ->
          query
          |> join(:inner, [document], collection in assoc(document, :collection))
          |> where([_document, collection], collection.name in ^names)
      end
    end

    defp apply_chunk_scope(query, allowed) do
      case CollectionScope.normalize!(allowed) do
        :all ->
          query

        {:only, []} ->
          where(query, [chunk, _document], is_nil(chunk.id))

        {:only, names} ->
          query
          |> join(:inner, [_chunk, document], collection in assoc(document, :collection))
          |> where([_chunk, _document, collection], collection.name in ^names)
      end
    end

    defp run_search("", _params, _repo, _allowed), do: []

    defp run_search(query, params, repo, allowed) do
      case requested_collection_scope(params["collections"], allowed) do
        {:ok, collection_opts} ->
          opts = build_search_opts(params, repo, collection_opts)

          case Arcana.search(query, opts) do
            {:ok, results} -> results
            {:error, _reason} -> []
          end

        :error ->
          []
      end
    end

    defp build_search_opts(params, repo, collection_opts) do
      [
        repo: repo,
        limit: parse_int(params["limit"], 10),
        threshold: parse_float(params["threshold"], 0.0),
        mode: parse_mode(params["mode"])
      ]
      |> add_source_id_opt(params["source_id"])
      |> Keyword.merge(collection_opts)
    end

    defp add_source_id_opt(opts, nil), do: opts
    defp add_source_id_opt(opts, ""), do: opts
    defp add_source_id_opt(opts, source_id), do: Keyword.put(opts, :source_id, source_id)

    defp requested_collection_scope(nil, allowed),
      do: {:ok, collection_scope_opts(CollectionScope.normalize!(allowed))}

    defp requested_collection_scope(collections, allowed) when is_list(collections) do
      requested = Enum.reject(collections, &(&1 == ""))

      case requested do
        [] ->
          {:ok, collection_scope_opts(CollectionScope.normalize!(allowed))}

        names ->
          requested_scope = CollectionScope.normalize!(names)
          allowed_scope = CollectionScope.normalize!(allowed)

          if CollectionScope.subset?(requested_scope, allowed_scope) do
            {:ok, collection_scope_opts(requested_scope)}
          else
            :error
          end
      end
    rescue
      ArgumentError -> :error
    end

    defp requested_collection_scope(_collections, _allowed), do: :error

    defp collection_scope_opts(:all), do: [collection: :all]
    defp collection_scope_opts({:only, names}), do: [collection: names]

    @impl true
    def render(assigns) do
      ~H"""
      <.dashboard_layout flash={@flash} stats={@stats} current_tab={:search} prefix={@prefix}>
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
                      <option value="vector">Vector</option>
                      <option value="keyword">Keyword</option>
                      <option value="hybrid">Hybrid</option>
                    </select>
                    <small class="arcana-search-mode-hint">
                      Vector: embedding similarity. Keyword: exact terms via Postgres full-text.
                      Hybrid: both fused by Reciprocal Rank Fusion.
                    </small>
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
                    <div class={"arcana-result-text #{if @expanded_result_id == result.id, do: "expanded", else: ""}"}><%= if @expanded_result_id == result.id, do: result.text, else: String.slice(result.text, 0, 200) <> if(String.length(result.text) > 200, do: "...", else: "") %></div>
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
end
