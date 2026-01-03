defmodule ArcanaWeb.MaintenanceLive do
  @moduledoc """
  LiveView for maintenance operations in Arcana.
  """
  use Phoenix.LiveView

  import Ecto.Query
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
       collections_for_assign: [],
       orphaned_stats: %{entities: 0, relationships: 0},
       assign_orphans_collection: nil,
       stats: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo
    collections = fetch_collections(repo)

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: Enum.map(collections, & &1.name))
    |> assign(collections_for_assign: collections)
    |> assign(orphaned_stats: count_orphaned_graph_data(repo))
  end

  defp fetch_collections(repo) do
    repo.all(from(c in Arcana.Collection, select: %{id: c.id, name: c.name}, order_by: c.name))
  rescue
    _ -> []
  end

  defp count_orphaned_graph_data(repo) do
    entities =
      repo.one(from(e in Arcana.Graph.Entity, where: is_nil(e.collection_id), select: count(e.id))) ||
        0

    relationships =
      repo.one(
        from(r in Arcana.Graph.Relationship, where: is_nil(r.collection_id), select: count(r.id))
      ) || 0

    %{entities: entities, relationships: relationships}
  rescue
    _ -> %{entities: 0, relationships: 0}
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

    Arcana.TaskSupervisor.start_child(fn ->
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

    Arcana.TaskSupervisor.start_child(fn ->
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

  def handle_event("select_assign_collection", %{"collection" => collection}, socket) do
    collection = if collection == "", do: nil, else: collection
    {:noreply, assign(socket, assign_orphans_collection: collection)}
  end

  def handle_event("assign_orphans", _params, socket) do
    repo = socket.assigns.repo
    collection_name = socket.assigns.assign_orphans_collection

    if collection_name do
      collection =
        Enum.find(socket.assigns.collections_for_assign, &(&1.name == collection_name))

      if collection do
        assign_orphaned_to_collection(repo, collection.id)

        socket =
          socket
          |> load_data()
          |> put_flash(:info, "Assigned orphaned graph data to #{collection_name}")

        {:noreply, socket}
      else
        {:noreply, put_flash(socket, :error, "Collection not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "Please select a collection")}
    end
  end

  def handle_event("delete_orphans", _params, socket) do
    repo = socket.assigns.repo
    {entities_deleted, relationships_deleted} = delete_orphaned_graph_data(repo)

    socket =
      socket
      |> load_data()
      |> put_flash(
        :info,
        "Deleted #{entities_deleted} orphaned entities and #{relationships_deleted} orphaned relationships"
      )

    {:noreply, socket}
  end

  defp assign_orphaned_to_collection(repo, collection_id) do
    repo.update_all(
      from(e in Arcana.Graph.Entity, where: is_nil(e.collection_id)),
      set: [collection_id: collection_id]
    )

    repo.update_all(
      from(r in Arcana.Graph.Relationship, where: is_nil(r.collection_id)),
      set: [collection_id: collection_id]
    )
  end

  defp delete_orphaned_graph_data(repo) do
    {rel_count, _} =
      repo.delete_all(from(r in Arcana.Graph.Relationship, where: is_nil(r.collection_id)))

    {entity_count, _} =
      repo.delete_all(from(e in Arcana.Graph.Entity, where: is_nil(e.collection_id)))

    {entity_count, rel_count}
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

        <%= if @orphaned_stats.entities > 0 or @orphaned_stats.relationships > 0 do %>
          <div class="arcana-maintenance-section arcana-orphan-section">
            <h3>Orphaned Graph Data</h3>
            <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
              These entities and relationships don't belong to any collection.
              Assign them to a collection or delete them.
            </p>

            <div class="arcana-doc-info" style="margin-bottom: 1rem;">
              <div class="arcana-doc-field">
                <label>Orphaned Entities</label>
                <span class="arcana-orphan-count"><%= @orphaned_stats.entities %></span>
              </div>
              <div class="arcana-doc-field">
                <label>Orphaned Relationships</label>
                <span class="arcana-orphan-count"><%= @orphaned_stats.relationships %></span>
              </div>
            </div>

            <div style="display: flex; gap: 0.75rem; align-items: stretch; flex-wrap: wrap;">
              <select
                phx-change="select_assign_collection"
                name="collection"
                style="padding: 0.5rem 0.75rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-size: 0.875rem; background: white; min-width: 160px;"
              >
                <option value="">Select collection...</option>
                <%= for collection <- @collections do %>
                  <option value={collection} selected={@assign_orphans_collection == collection}>
                    <%= collection %>
                  </option>
                <% end %>
              </select>
              <button
                phx-click="assign_orphans"
                disabled={is_nil(@assign_orphans_collection)}
                class="arcana-assign-btn"
                style={"background: #3b82f6; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap; opacity: #{if is_nil(@assign_orphans_collection), do: "0.5", else: "1"};"}
              >
                Assign to Collection
              </button>
              <button
                phx-click="delete_orphans"
                data-confirm="Are you sure you want to delete all orphaned entities and relationships? This cannot be undone."
                style="background: #ef4444; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap;"
              >
                Delete All Orphans
              </button>
            </div>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end
end
