# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Only
# ArcanaWeb.TaskSupervisor is phoenix-free and stays available.

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.CollectionsLive do
    @moduledoc """
    LiveView for managing collections in Arcana.
    """
    use Phoenix.LiveView

    import Ecto.Query
    import ArcanaWeb.DashboardComponents

    alias Arcana.Collection

    @impl true
    def mount(_params, session, socket) do
      repo = get_repo_from_session(session)

      {:ok,
       socket
       |> assign(repo: repo)
       |> assign(editing_collection: nil, confirm_delete_collection: nil)
       |> assign(stats: nil, collections: [], show_graph_stats: false)}
    end

    @impl true
    def handle_params(_params, _uri, socket) do
      {:noreply, load_data(socket)}
    end

    defp load_data(socket) do
      repo = socket.assigns.repo
      allowed = socket.assigns.allowed_collections
      {collections, has_graph_data} = load_collections_with_stats(repo, allowed)

      socket
      |> assign(stats: load_stats(repo, allowed))
      |> assign(collections: collections)
      |> assign(show_graph_stats: has_graph_data)
    end

    defp load_collections_with_stats(repo, allowed) do
      # Base collection data with document count
      base_query =
        from(c in Collection,
          left_join: d in Arcana.Document,
          on: d.collection_id == c.id,
          group_by: c.id,
          order_by: c.name,
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            document_count: count(d.id)
          }
        )

      base_query =
        case allowed do
          :all -> base_query
          names when is_list(names) -> where(base_query, [c], c.name in ^names)
        end

      collections = repo.all(base_query)

      # Add chunk counts
      chunk_counts =
        repo.all(
          from(ch in Arcana.Chunk,
            join: d in Arcana.Document,
            on: ch.document_id == d.id,
            group_by: d.collection_id,
            select: {d.collection_id, count(ch.id)}
          )
        )
        |> Map.new()

      collections =
        Enum.map(collections, fn c ->
          Map.put(c, :chunk_count, Map.get(chunk_counts, c.id, 0))
        end)

      # Always try to add graph stats - show columns if any data exists
      add_graph_stats(repo, collections)
    end

    defp add_graph_stats(repo, collections) do
      entity_counts =
        repo.all(
          from(e in Arcana.Graph.Entity,
            group_by: e.collection_id,
            select: {e.collection_id, count(e.id)}
          )
        )
        |> Map.new()

      # Relationships don't have collection_id directly - join through source entity
      relationship_counts =
        repo.all(
          from(r in Arcana.Graph.Relationship,
            join: e in Arcana.Graph.Entity,
            on: r.source_id == e.id,
            group_by: e.collection_id,
            select: {e.collection_id, count(r.id)}
          )
        )
        |> Map.new()

      community_counts =
        repo.all(
          from(c in Arcana.Graph.Community,
            group_by: c.collection_id,
            select: {c.collection_id, count(c.id)}
          )
        )
        |> Map.new()

      collections_with_stats =
        Enum.map(collections, fn c ->
          c
          |> Map.put(:entity_count, Map.get(entity_counts, c.id, 0))
          |> Map.put(:relationship_count, Map.get(relationship_counts, c.id, 0))
          |> Map.put(:community_count, Map.get(community_counts, c.id, 0))
        end)

      # Derived from the visible collections, not the global count maps:
      # otherwise the graph columns render (leaking that graph data exists
      # at all) because some collection outside the allowed set has entities.
      has_graph_data =
        Enum.any?(
          collections_with_stats,
          &(&1.entity_count > 0 or &1.relationship_count > 0)
        )

      {collections_with_stats, has_graph_data}
    rescue
      # Tables might not exist
      _ -> {collections, false}
    end

    @impl true
    def handle_event("create_collection", %{"collection" => params}, socket) do
      repo = socket.assigns.repo
      name = params["name"] || ""
      description = params["description"]

      if allowed_collection?(socket.assigns.allowed_collections, name) do
        case Collection.get_or_create(name, repo, description) do
          {:ok, _collection} ->
            {:noreply, load_data(socket)}

          {:error, changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to create collection: #{inspect(changeset.errors)}"
             )}
        end
      else
        {:noreply, put_flash(socket, :error, "Collection #{inspect(name)} is not allowed")}
      end
    end

    def handle_event("edit_collection", %{"id" => id}, socket) do
      {:noreply, assign(socket, editing_collection: fetch_allowed_collection(socket, id))}
    end

    def handle_event("cancel_edit_collection", _params, socket) do
      {:noreply, assign(socket, editing_collection: nil)}
    end

    def handle_event("update_collection", %{"id" => id, "collection" => params}, socket) do
      case fetch_allowed_collection(socket, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Collection is not allowed")}

        collection ->
          update_allowed_collection(socket, collection, params)
      end
    end

    def handle_event("confirm_delete_collection", %{"id" => id}, socket) do
      {:noreply, assign(socket, confirm_delete_collection: id)}
    end

    def handle_event("cancel_delete_collection", _params, socket) do
      {:noreply, assign(socket, confirm_delete_collection: nil)}
    end

    def handle_event("delete_collection", %{"id" => id}, socket) do
      repo = socket.assigns.repo

      case fetch_allowed_collection(socket, id) do
        nil ->
          {:noreply, assign(socket, confirm_delete_collection: nil)}

        collection ->
          repo.delete!(collection)
          {:noreply, socket |> assign(confirm_delete_collection: nil) |> load_data()}
      end
    end

    # Restricted dashboards can edit a description but never rename. Only
    # validating the target name against the allowed set isn't enough:
    # allow-lists can overlap, so renaming onto a shared name would drag
    # this tenant's documents into another tenant's scope while still
    # passing the check. The name input is disabled in the form, so a
    # legitimate edit never carries a new name and only forged events hit
    # this rejection.
    defp update_allowed_collection(socket, collection, params) do
      name = params["name"] || collection.name

      if name != collection.name and socket.assigns.allowed_collections != :all do
        {:noreply, put_flash(socket, :error, "Renaming collections is not allowed")}
      else
        changeset =
          Collection.changeset(collection, %{
            name: name,
            description: params["description"]
          })

        update_collection(socket, socket.assigns.repo, changeset)
      end
    end

    defp update_collection(socket, repo, changeset) do
      case repo.update(changeset) do
        {:ok, _updated} ->
          {:noreply, socket |> assign(editing_collection: nil) |> load_data()}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update: #{inspect(changeset.errors)}")}
      end
    end

    # Fetches a collection by id only when its name is inside the allowed
    # set. Forged ids pointing at collections outside the scope resolve to
    # nil, the same as a missing row; ids that aren't UUIDs at all are
    # rejected before the query would raise an Ecto.Query.CastError.
    defp fetch_allowed_collection(socket, id) do
      with {:ok, uuid} <- Ecto.UUID.cast(id),
           collection when not is_nil(collection) <- socket.assigns.repo.get(Collection, uuid),
           true <- allowed_collection?(socket.assigns.allowed_collections, collection.name) do
        collection
      else
        _ -> nil
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.dashboard_layout stats={@stats} current_tab={:collections} prefix={@prefix}>
        <div class="arcana-collections">
          <h2>Collections</h2>
          <p class="arcana-tab-description">
            Organize documents into collections for scoped searches and better organization.
          </p>

          <%= if @allowed_collections == [] do %>
            <div class="arcana-empty">
              No collections are available on this dashboard. Ask an administrator to grant
              access to a collection.
            </div>
          <% else %>
            <.collections_manager
              collections={@collections}
              show_graph_stats={@show_graph_stats}
              editing_collection={@editing_collection}
              confirm_delete_collection={@confirm_delete_collection}
            />
          <% end %>
        </div>
      </.dashboard_layout>
      """
    end

    defp collections_manager(assigns) do
      ~H"""
      <div>
        <div class="arcana-ingest-form">
          <h3>Create Collection</h3>
          <form id="new-collection-form" phx-submit="create_collection">
            <div class="arcana-form-row" style="margin-bottom: 0.75rem;">
              <input
                type="text"
                name="collection[name]"
                placeholder="Collection name"
                class="arcana-input"
                style="flex: 1; max-width: 300px;"
                required
              />
            </div>
            <div class="arcana-form-row">
              <input
                type="text"
                name="collection[description]"
                placeholder="Description (optional) - helps the agent select the right collection"
                class="arcana-input"
                style="flex: 1;"
              />
              <button type="submit" class="arcana-btn arcana-btn-primary">
                Create
              </button>
            </div>
          </form>
        </div>

        <div class="arcana-doc-list">
          <%= if Enum.empty?(@collections) do %>
            <div class="arcana-empty">No collections yet. Create one above.</div>
          <% else %>
            <table class="arcana-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Description</th>
                  <th>Docs</th>
                  <th>Chunks</th>
                  <%= if @show_graph_stats do %>
                    <th>Entities</th>
                    <th>Rels</th>
                    <th>Communities</th>
                  <% end %>
                  <th style="width: 120px;">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for collection <- @collections do %>
                  <tr id={"collection-#{collection.name}"}>
                    <%= if @editing_collection && @editing_collection.id == collection.id do %>
                      <td colspan={if @show_graph_stats, do: 8, else: 5}>
                        <form
                          id={"edit-collection-form-#{collection.id}"}
                          phx-submit="update_collection"
                          phx-value-id={collection.id}
                          class="arcana-edit-form"
                        >
                          <div class="arcana-form-row">
                            <input
                              type="text"
                              name="collection[name]"
                              value={collection.name}
                              class="arcana-input"
                              disabled
                            />
                            <input
                              type="text"
                              name="collection[description]"
                              value={collection.description || ""}
                              placeholder="Description"
                              class="arcana-input"
                              style="flex: 2;"
                            />
                            <button type="submit" class="arcana-btn arcana-btn-primary">Save</button>
                            <button
                              type="button"
                              class="arcana-btn"
                              phx-click="cancel_edit_collection"
                            >
                              Cancel
                            </button>
                          </div>
                        </form>
                      </td>
                    <% else %>
                      <td><code><%= collection.name %></code></td>
                      <td><%= collection.description || "-" %></td>
                      <td><%= collection.document_count %></td>
                      <td><%= collection.chunk_count %></td>
                      <%= if @show_graph_stats do %>
                        <td><%= collection[:entity_count] || 0 %></td>
                        <td><%= collection[:relationship_count] || 0 %></td>
                        <td><%= collection[:community_count] || 0 %></td>
                      <% end %>
                      <td>
                        <%= if @confirm_delete_collection == collection.id do %>
                          <div class="arcana-confirm-delete">
                            <span>Delete?</span>
                            <button
                              id="confirm-delete"
                              class="arcana-btn arcana-btn-danger"
                              phx-click="delete_collection"
                              phx-value-id={collection.id}
                            >
                              Yes
                            </button>
                            <button
                              class="arcana-btn"
                              phx-click="cancel_delete_collection"
                            >
                              No
                            </button>
                          </div>
                        <% else %>
                          <div class="arcana-actions-cell">
                            <button
                              id={"edit-collection-#{collection.id}"}
                              class="arcana-icon-btn"
                              phx-click="edit_collection"
                              phx-value-id={collection.id}
                              title="Edit collection"
                            >
                              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path>
                                <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path>
                              </svg>
                            </button>
                            <button
                              id={"delete-collection-#{collection.id}"}
                              class="arcana-delete-btn"
                              phx-click="confirm_delete_collection"
                              phx-value-id={collection.id}
                              title="Delete collection"
                            >
                              <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                                <polyline points="3 6 5 6 21 6"></polyline>
                                <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                                <line x1="10" y1="11" x2="10" y2="17"></line>
                                <line x1="14" y1="11" x2="14" y2="17"></line>
                              </svg>
                            </button>
                          </div>
                        <% end %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
      """
    end
  end
end
