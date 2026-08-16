# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Only
# ArcanaWeb.TaskSupervisor is phoenix-free and stays available.

if Code.ensure_loaded?(Phoenix.LiveView) do
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
         detect_communities_running: false,
         detect_communities_progress: nil,
         detect_communities_collection: nil,
         summarize_communities_running: false,
         summarize_communities_progress: nil,
         summarize_communities_collection: nil,
         llm_configured?: not is_nil(Arcana.Config.get_env(:llm)),
         unsummarized_communities: 0,
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
      allowed = socket.assigns.allowed_collections
      collections = fetch_collections(repo, allowed)

      socket
      |> assign(stats: load_stats(repo, allowed))
      |> assign(collections: Enum.map(collections, & &1.name))
      |> assign(collections_for_assign: collections)
      |> assign(orphaned_stats: count_orphaned_graph_data(repo))
      |> assign(unsummarized_communities: count_unsummarized_communities(repo))
    end

    # Communities the summarizer would pick up: without a summary they're
    # invisible to `ask(graph: true)`, dirty ones carry a stale summary.
    # Scoped to the levels that get summarized, so the hint can reach zero.
    defp count_unsummarized_communities(repo) do
      repo.one(
        from(c in Arcana.Graph.Community,
          where: is_nil(c.summary) or c.summary == "" or c.dirty,
          where: ^summarizable_levels(),
          select: count(c.id)
        )
      ) || 0
    rescue
      _ -> 0
    end

    defp summarizable_levels do
      case Arcana.Graph.summary_levels() do
        :all -> dynamic([c], not is_nil(c.level))
        levels -> dynamic([c], c.level in ^levels)
      end
    end

    defp fetch_collections(repo, allowed) do
      query = from(c in Arcana.Collection, select: %{id: c.id, name: c.name}, order_by: c.name)

      query =
        case allowed do
          :all -> query
          names when is_list(names) -> where(query, [c], c.name in ^names)
        end

      repo.all(query)
    rescue
      _ -> []
    end

    # Maintenance actions take a collection selection where nil means "all
    # collections". Restricted dashboards must never run a global action, so
    # nil (and any name outside the allowed set) is rejected.
    defp validate_maintenance_collection(socket, collection) do
      allowed = socket.assigns.allowed_collections

      cond do
        allowed == :all -> {:ok, collection}
        is_binary(collection) and collection in allowed -> {:ok, collection}
        true -> :error
      end
    end

    defp count_orphaned_graph_data(repo) do
      entities =
        repo.one(
          from(e in Arcana.Graph.Entity, where: is_nil(e.collection_id), select: count(e.id))
        ) ||
          0

      # Relationships don't have collection_id - count those connected to orphaned entities
      relationships =
        repo.one(
          from(r in Arcana.Graph.Relationship,
            join: source in Arcana.Graph.Entity,
            on: r.source_id == source.id,
            where: is_nil(source.collection_id),
            select: count(r.id)
          )
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

      case validate_maintenance_collection(socket, collection) do
        {:ok, collection} -> {:noreply, assign(socket, reembed_collection: collection)}
        :error -> {:noreply, socket}
      end
    end

    def handle_event("reembed", _params, socket) do
      case validate_maintenance_collection(socket, socket.assigns.reembed_collection) do
        {:ok, collection} -> {:noreply, start_reembed(socket, collection)}
        :error -> {:noreply, put_flash(socket, :error, "Select an allowed collection first")}
      end
    end

    def handle_event("select_rebuild_collection", %{"collection" => collection}, socket) do
      collection = if collection == "", do: nil, else: collection

      case validate_maintenance_collection(socket, collection) do
        {:ok, collection} -> {:noreply, assign(socket, rebuild_graph_collection: collection)}
        :error -> {:noreply, socket}
      end
    end

    def handle_event("rebuild_graph", _params, socket) do
      case validate_maintenance_collection(socket, socket.assigns.rebuild_graph_collection) do
        {:ok, collection} -> {:noreply, start_rebuild_graph(socket, collection)}
        :error -> {:noreply, put_flash(socket, :error, "Select an allowed collection first")}
      end
    end

    def handle_event(
          "select_detect_communities_collection",
          %{"collection" => collection},
          socket
        ) do
      collection = if collection == "", do: nil, else: collection

      case validate_maintenance_collection(socket, collection) do
        {:ok, collection} ->
          {:noreply, assign(socket, detect_communities_collection: collection)}

        :error ->
          {:noreply, socket}
      end
    end

    def handle_event("detect_communities", _params, socket) do
      case validate_maintenance_collection(
             socket,
             socket.assigns.detect_communities_collection
           ) do
        {:ok, collection} -> {:noreply, start_detect_communities(socket, collection)}
        :error -> {:noreply, put_flash(socket, :error, "Select an allowed collection first")}
      end
    end

    def handle_event(
          "select_summarize_communities_collection",
          %{"collection" => collection},
          socket
        ) do
      collection = if collection == "", do: nil, else: collection
      {:noreply, assign(socket, summarize_communities_collection: collection)}
    end

    def handle_event("summarize_communities", _params, socket) do
      if socket.assigns.llm_configured? do
        {:noreply, start_summarize_communities(socket)}
      else
        {:noreply,
         put_flash(socket, :error, "No LLM configured. Set :arcana, :llm in your config.")}
      end
    end

    def handle_event("select_assign_collection", %{"collection" => collection}, socket) do
      collection = if collection == "", do: nil, else: collection
      {:noreply, assign(socket, assign_orphans_collection: collection)}
    end

    # Orphaned graph data belongs to no collection, so assigning or deleting
    # it is inherently a cross-collection operation: restricted dashboards
    # can't run it at all.
    def handle_event("assign_orphans", _params, socket) do
      repo = socket.assigns.repo
      collection_name = socket.assigns.assign_orphans_collection

      cond do
        socket.assigns.allowed_collections != :all ->
          {:noreply, socket}

        is_nil(collection_name) ->
          {:noreply, put_flash(socket, :error, "Please select a collection")}

        true ->
          assign_orphans_to_named_collection(socket, repo, collection_name)
      end
    end

    def handle_event("delete_orphans", _params, socket) do
      if socket.assigns.allowed_collections == :all do
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
      else
        {:noreply, socket}
      end
    end

    defp assign_orphans_to_named_collection(socket, repo, collection_name) do
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
    end

    defp start_reembed(socket, collection) do
      repo = socket.assigns.repo
      parent = self()

      socket = assign(socket, reembed_running: true, reembed_progress: %{current: 0, total: 0})

      ArcanaWeb.TaskSupervisor.start_child(fn ->
        progress_fn = fn current, total ->
          send(parent, {:reembed_progress, current, total})
        end

        opts = maintenance_collection_opts([batch_size: 50, progress: progress_fn], collection)
        result = Arcana.Maintenance.reembed(repo, opts)
        send(parent, {:reembed_complete, result})
      end)

      socket
    end

    defp start_rebuild_graph(socket, collection) do
      repo = socket.assigns.repo
      parent = self()

      socket =
        assign(socket,
          rebuild_graph_running: true,
          rebuild_graph_progress: %{current: 0, total: 0}
        )

      ArcanaWeb.TaskSupervisor.start_child(fn ->
        progress_fn = progress_sender(parent, :rebuild_graph_progress)

        opts = maintenance_collection_opts([progress: progress_fn], collection)
        result = Arcana.Maintenance.rebuild_graph(repo, opts)
        send(parent, {:rebuild_graph_complete, result})
      end)

      socket
    end

    defp start_detect_communities(socket, collection) do
      repo = socket.assigns.repo
      parent = self()

      socket =
        assign(socket,
          detect_communities_running: true,
          detect_communities_progress: %{current: 0, total: 0}
        )

      ArcanaWeb.TaskSupervisor.start_child(fn ->
        progress_fn = progress_sender(parent, :detect_communities_progress)

        opts = maintenance_collection_opts([progress: progress_fn], collection)
        result = Arcana.Maintenance.detect_communities(repo, opts)
        send(parent, {:detect_communities_complete, result})
      end)

      socket
    end

    # A collection name with no row resolves to "no filter", which silently
    # turns a per-collection action into a global one: re-embedding every
    # document in the database, rebuilding every graph. Strict resolution
    # turns that into {:error, {:unknown_collection, name}}, which the
    # completion handlers already render as a flash. The name can go missing
    # on any dashboard (never ingested yet, or deleted from another tab), so
    # this holds for restricted and unrestricted mounts alike. nil is the
    # explicit "all collections" choice and stays unstrict — restricted
    # dashboards never get that far (see validate_maintenance_collection/2).
    defp maintenance_collection_opts(opts, nil), do: opts

    defp maintenance_collection_opts(opts, collection) when is_binary(collection),
      do: Keyword.merge(opts, collection: collection, strict_collections: true)

    defp start_summarize_communities(socket) do
      repo = socket.assigns.repo
      collection = socket.assigns.summarize_communities_collection
      parent = self()

      ArcanaWeb.TaskSupervisor.start_child(fn ->
        progress_fn = progress_sender(parent, :summarize_communities_progress)

        opts = [progress: progress_fn]
        opts = if collection, do: Keyword.put(opts, :collection, collection), else: opts

        result =
          try do
            Arcana.Maintenance.summarize_communities(repo, opts)
          rescue
            error -> {:error, Exception.message(error)}
          end

        send(parent, {:summarize_communities_complete, result})
      end)

      assign(socket,
        summarize_communities_running: true,
        summarize_communities_progress: %{current: 0, total: 0}
      )
    end

    # Maintenance progress callbacks are called both with numeric
    # `current, total` and with `stage, payload` pairs (`:collection_start`
    # and friends). Only the numeric form drives the progress bar; the
    # stage form is ignored so the callers fall back to numeric progress.
    defp progress_sender(parent, tag) do
      fn
        current, total when is_integer(current) and is_integer(total) ->
          send(parent, {tag, current, total})

        _stage, _payload ->
          :ok
      end
    end

    defp assign_orphaned_to_collection(repo, collection_id) do
      # Only entities have collection_id - relationships reference entities
      repo.update_all(
        from(e in Arcana.Graph.Entity, where: is_nil(e.collection_id)),
        set: [collection_id: collection_id]
      )
    end

    defp delete_orphaned_graph_data(repo) do
      # Get orphaned entity IDs first
      orphaned_entity_ids =
        repo.all(
          from(e in Arcana.Graph.Entity,
            where: is_nil(e.collection_id),
            select: e.id
          )
        )

      # Delete relationships connected to orphaned entities (must be done first)
      {rel_count, _} =
        if orphaned_entity_ids != [] do
          repo.delete_all(
            from(r in Arcana.Graph.Relationship,
              where: r.source_id in ^orphaned_entity_ids or r.target_id in ^orphaned_entity_ids
            )
          )
        else
          {0, nil}
        end

      # Then delete orphaned entities
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

    def handle_info({:detect_communities_progress, current, total}, socket) do
      {:noreply, assign(socket, detect_communities_progress: %{current: current, total: total})}
    end

    def handle_info({:detect_communities_complete, result}, socket) do
      socket =
        case result do
          {:ok, %{communities: communities}} ->
            socket
            |> assign(detect_communities_running: false, detect_communities_progress: nil)
            |> load_data()
            |> put_flash(:info, "Detected #{communities} communities successfully!")

          {:error, reason} ->
            socket
            |> assign(detect_communities_running: false, detect_communities_progress: nil)
            |> put_flash(:error, "Community detection failed: #{inspect(reason)}")
        end

      {:noreply, socket}
    end

    def handle_info({:summarize_communities_progress, current, total}, socket) do
      {:noreply,
       assign(socket, summarize_communities_progress: %{current: current, total: total})}
    end

    def handle_info({:summarize_communities_complete, result}, socket) do
      socket =
        case result do
          {:ok, %{summaries: summaries}} ->
            socket
            |> assign(summarize_communities_running: false, summarize_communities_progress: nil)
            |> load_data()
            |> put_flash(:info, "Summarized #{summaries} communities successfully!")

          {:error, reason} ->
            socket
            |> assign(summarize_communities_running: false, summarize_communities_progress: nil)
            |> put_flash(:error, "Community summarization failed: #{inspect(reason)}")
        end

      {:noreply, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.dashboard_layout stats={@stats} current_tab={:maintenance} prefix={@prefix}>
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
                  <%= if @allowed_collections == :all do %>
                    <option value="">All Collections</option>
                  <% end %>
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
                  <%= if @allowed_collections == :all do %>
                    <option value="">All Collections</option>
                  <% end %>
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

          <div class="arcana-maintenance-section">
            <h3>Detect Communities</h3>
            <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
              Run Leiden community detection on the knowledge graph.
              Communities enable global queries by grouping related entities.
            </p>

            <%= if @detect_communities_running do %>
              <div class="arcana-progress">
                <div class="arcana-progress-text">
                  Detecting communities... <%= @detect_communities_progress.current %>/<%= @detect_communities_progress.total %> collections
                </div>
                <%= if @detect_communities_progress.total > 0 do %>
                  <progress
                    value={@detect_communities_progress.current}
                    max={@detect_communities_progress.total}
                    style="width: 100%; height: 1rem;"
                  >
                    <%= round(@detect_communities_progress.current / @detect_communities_progress.total * 100) %>%
                  </progress>
                <% end %>
              </div>
            <% else %>
              <div style="display: flex; gap: 0.75rem; align-items: stretch;">
                <select
                  phx-change="select_detect_communities_collection"
                  name="collection"
                  style="padding: 0.5rem 0.75rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-size: 0.875rem; background: white; min-width: 160px;"
                >
                  <%= if @allowed_collections == :all do %>
                    <option value="">All Collections</option>
                  <% end %>
                  <%= for collection <- @collections do %>
                    <option value={collection} selected={@detect_communities_collection == collection}>
                      <%= collection %>
                    </option>
                  <% end %>
                </select>
                <button
                  phx-click="detect_communities"
                  style="background: #8b5cf6; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap;"
                >
                  Detect Communities
                </button>
              </div>
            <% end %>
          </div>

          <div class="arcana-maintenance-section">
            <h3>Summarize Communities</h3>
            <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
              Generate LLM summaries for detected communities.
              Detection alone isn't enough: communities without a summary are skipped
              when answering with <code>graph: true</code>.
            </p>

            <%= if @unsummarized_communities > 0 do %>
              <p class="arcana-summarize-hint" style="color: #b45309; margin-bottom: 1rem; font-size: 0.875rem;">
                <%= @unsummarized_communities %> communities need summarizing.
              </p>
            <% end %>

            <%= if @llm_configured? do %>
              <%= if @summarize_communities_running do %>
                <div class="arcana-progress">
                  <div class="arcana-progress-text">
                    Summarizing communities... <%= @summarize_communities_progress.current %>/<%= @summarize_communities_progress.total %> collections
                  </div>
                  <%= if @summarize_communities_progress.total > 0 do %>
                    <progress
                      value={@summarize_communities_progress.current}
                      max={@summarize_communities_progress.total}
                      style="width: 100%; height: 1rem;"
                    >
                      <%= round(
                        @summarize_communities_progress.current /
                          @summarize_communities_progress.total * 100
                      ) %>%
                    </progress>
                  <% end %>
                </div>
              <% else %>
                <div style="display: flex; gap: 0.75rem; align-items: stretch;">
                  <select
                    phx-change="select_summarize_communities_collection"
                    name="collection"
                    style="padding: 0.5rem 0.75rem; border: 1px solid #d1d5db; border-radius: 0.375rem; font-size: 0.875rem; background: white; min-width: 160px;"
                  >
                    <option value="">All Collections</option>
                    <%= for collection <- @collections do %>
                      <option
                        value={collection}
                        selected={@summarize_communities_collection == collection}
                      >
                        <%= collection %>
                      </option>
                    <% end %>
                  </select>
                  <button
                    phx-click="summarize_communities"
                    style="background: #6366f1; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; white-space: nowrap;"
                  >
                    Summarize Communities
                  </button>
                </div>
              <% end %>
            <% else %>
              <div style="display: flex; gap: 0.75rem; align-items: center;">
                <button
                  disabled
                  class="arcana-summarize-btn"
                  style="background: #9ca3af; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: not-allowed; white-space: nowrap; opacity: 0.5;"
                >
                  Summarize Communities
                </button>
                <span style="color: #6b7280; font-size: 0.875rem;">
                  No LLM configured. Set :arcana, :llm in your config.
                </span>
              </div>
            <% end %>
          </div>

          <%= if @allowed_collections == :all and
                (@orphaned_stats.entities > 0 or @orphaned_stats.relationships > 0) do %>
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
end
