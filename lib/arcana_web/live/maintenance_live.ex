defmodule ArcanaWeb.MaintenanceLive do
  @moduledoc """
  LiveView for maintenance operations in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       reembed_running: false,
       reembed_progress: nil,
       reembed_collection: nil,
       embedding_info: get_embedding_info(),
       rebuild_graph_running: false,
       rebuild_graph_progress: nil,
       rebuild_graph_collection: nil,
       graph_info: get_graph_info(),
       collections: [],
       stats: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: fetch_collection_names(repo))
  end

  defp fetch_collection_names(repo) do
    import Ecto.Query
    repo.all(from(c in Arcana.Collection, select: c.name, order_by: c.name))
  rescue
    _ -> []
  end

  defp get_embedding_info do
    Arcana.Maintenance.embedding_info()
  rescue
    _ -> %{type: :unknown, dimensions: nil}
  end

  defp get_graph_info do
    Arcana.Maintenance.graph_info()
  rescue
    _ -> %{enabled: false, extractor_type: :unknown}
  end

  @impl true
  def handle_event("select_reembed_collection", %{"collection" => collection}, socket) do
    collection = if collection == "", do: nil, else: collection
    {:noreply, assign(socket, reembed_collection: collection)}
  end

  def handle_event("reembed", _params, socket) do
    repo = socket.assigns.repo
    collection = socket.assigns.reembed_collection
    parent = self()

    socket = assign(socket, reembed_running: true, reembed_progress: %{current: 0, total: 0})

    Task.start(fn ->
      progress_fn = fn current, total ->
        send(parent, {:reembed_progress, current, total})
      end

      opts = [batch_size: 50, progress: progress_fn]
      opts = if collection, do: Keyword.put(opts, :collection, collection), else: opts
      result = Arcana.Maintenance.reembed(repo, opts)
      send(parent, {:reembed_complete, result})
    end)

    {:noreply, socket}
  end

  def handle_event("select_rebuild_collection", %{"collection" => collection}, socket) do
    collection = if collection == "", do: nil, else: collection
    {:noreply, assign(socket, rebuild_graph_collection: collection)}
  end

  def handle_event("rebuild_graph", _params, socket) do
    repo = socket.assigns.repo
    collection = socket.assigns.rebuild_graph_collection
    parent = self()

    socket =
      assign(socket, rebuild_graph_running: true, rebuild_graph_progress: %{current: 0, total: 0})

    Task.start(fn ->
      progress_fn = fn current, total ->
        send(parent, {:rebuild_graph_progress, current, total})
      end

      opts = [progress: progress_fn]
      opts = if collection, do: Keyword.put(opts, :collection, collection), else: opts
      result = Arcana.Maintenance.rebuild_graph(repo, opts)
      send(parent, {:rebuild_graph_complete, result})
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:reembed_progress, current, total}, socket) do
    {:noreply, assign(socket, reembed_progress: %{current: current, total: total})}
  end

  def handle_info({:reembed_complete, result}, socket) do
    socket =
      case result do
        {:ok, %{reembedded: count}} ->
          socket
          |> assign(reembed_running: false, reembed_progress: nil)
          |> put_flash(:info, "Re-embedded #{count} chunks successfully!")

        {:error, reason} ->
          socket
          |> assign(reembed_running: false, reembed_progress: nil)
          |> put_flash(:error, "Re-embedding failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_info({:rebuild_graph_progress, current, total}, socket) do
    {:noreply, assign(socket, rebuild_graph_progress: %{current: current, total: total})}
  end

  def handle_info({:rebuild_graph_complete, result}, socket) do
    socket =
      case result do
        {:ok, %{entities: entities, relationships: relationships}} ->
          socket
          |> assign(rebuild_graph_running: false, rebuild_graph_progress: nil)
          |> load_data()
          |> put_flash(
            :info,
            "Rebuilt graph: #{entities} entities, #{relationships} relationships"
          )

        {:error, reason} ->
          socket
          |> assign(rebuild_graph_running: false, rebuild_graph_progress: nil)
          |> put_flash(:error, "Rebuild graph failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:maintenance}>
      <div class="arcana-maintenance">
        <h2>Maintenance</h2>
        <p class="arcana-tab-description">
          View embedding configuration and re-embed documents if settings change.
        </p>

        <div class="arcana-maintenance-section">
          <h3>Embedding Configuration</h3>
          <div class="arcana-doc-info">
            <div class="arcana-doc-field">
              <label>Type</label>
              <span><%= @embedding_info.type %></span>
            </div>
            <%= if @embedding_info[:model] do %>
              <div class="arcana-doc-field">
                <label>Model</label>
                <span><%= @embedding_info.model %></span>
              </div>
            <% end %>
            <div class="arcana-doc-field">
              <label>Dimensions</label>
              <span><%= @embedding_info.dimensions || "Unknown" %></span>
            </div>
          </div>
        </div>

        <div class="arcana-maintenance-section">
          <h3>Re-embed Chunks</h3>
          <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
            Re-embed chunks using the current embedding configuration.
            Use this after changing embedding models.
          </p>

          <%= if @reembed_running do %>
            <div class="arcana-progress">
              <div class="arcana-progress-text">
                Re-embedding... <%= @reembed_progress.current %>/<%= @reembed_progress.total %>
              </div>
              <%= if @reembed_progress.total > 0 do %>
                <progress
                  value={@reembed_progress.current}
                  max={@reembed_progress.total}
                  style="width: 100%; height: 1rem;"
                >
                  <%= round(@reembed_progress.current / @reembed_progress.total * 100) %>%
                </progress>
              <% end %>
            </div>
          <% else %>
            <div style="display: flex; gap: 0.75rem; align-items: stretch;">
              <select
                phx-change="select_reembed_collection"
                name="collection"
                style="padding: 0.5rem 0.75rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-size: 0.875rem; background: white; min-width: 160px;"
              >
                <option value="">All Collections</option>
                <%= for collection <- @collections do %>
                  <option value={collection} selected={@reembed_collection == collection}>
                    <%= collection %>
                  </option>
                <% end %>
              </select>
              <button
                phx-click="reembed"
                style="background: #7c3aed; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap;"
              >
                Re-embed
              </button>
            </div>
          <% end %>
        </div>

        <div class="arcana-maintenance-section">
          <h3>Graph Configuration</h3>
          <div class="arcana-doc-info">
            <div class="arcana-doc-field">
              <label>Status</label>
              <span class={"arcana-status-badge #{if @graph_info.enabled, do: "enabled", else: "disabled"}"}>
                <%= if @graph_info.enabled, do: "Enabled", else: "Disabled" %>
              </span>
            </div>
            <div class="arcana-doc-field">
              <label>Extractor</label>
              <span>
                <%= @graph_info.extractor_name || @graph_info.extractor_type %>
                <%= if @graph_info.extractor_type == :combined do %>
                  <span style="color: #6b7280; font-size: 0.75rem;">(combined)</span>
                <% end %>
              </span>
            </div>
            <div class="arcana-doc-field">
              <label>Community Levels</label>
              <span><%= @graph_info.community_levels %></span>
            </div>
          </div>
        </div>

        <div class="arcana-maintenance-section">
          <h3>Rebuild Knowledge Graph</h3>
          <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
            Clear and rebuild the knowledge graph.
            Use this after changing graph extractor configuration or enabling relationship extraction.
          </p>

          <%= if @rebuild_graph_running do %>
            <div class="arcana-progress">
              <div class="arcana-progress-text">
                Rebuilding graph... <%= @rebuild_graph_progress.current %>/<%= @rebuild_graph_progress.total %> collections
              </div>
              <%= if @rebuild_graph_progress.total > 0 do %>
                <progress
                  value={@rebuild_graph_progress.current}
                  max={@rebuild_graph_progress.total}
                  style="width: 100%; height: 1rem;"
                >
                  <%= round(@rebuild_graph_progress.current / @rebuild_graph_progress.total * 100) %>%
                </progress>
              <% end %>
            </div>
          <% else %>
            <div style="display: flex; gap: 0.75rem; align-items: stretch;">
              <select
                phx-change="select_rebuild_collection"
                name="collection"
                style="padding: 0.5rem 0.75rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-size: 0.875rem; background: white; min-width: 160px;"
              >
                <option value="">All Collections</option>
                <%= for collection <- @collections do %>
                  <option value={collection} selected={@rebuild_graph_collection == collection}>
                    <%= collection %>
                  </option>
                <% end %>
              </select>
              <button
                phx-click="rebuild_graph"
                style="background: #10b981; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap;"
              >
                Rebuild Graph
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
