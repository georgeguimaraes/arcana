defmodule ArcanaWeb.CollectionsLive do
  @moduledoc """
  LiveView for managing collections in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  alias Arcana.Collection

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(editing_collection: nil, confirm_delete_collection: nil)
     |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: load_collections(repo))
  end

  @impl true
  def handle_event("create_collection", %{"collection" => params}, socket) do
    repo = socket.assigns.repo
    name = params["name"] || ""
    description = params["description"]

    case Collection.get_or_create(name, repo, description) do
      {:ok, _collection} ->
        {:noreply, load_data(socket)}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to create collection: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("edit_collection", %{"id" => id}, socket) do
    repo = socket.assigns.repo
    collection = repo.get(Collection, id)
    {:noreply, assign(socket, editing_collection: collection)}
  end

  def handle_event("cancel_edit_collection", _params, socket) do
    {:noreply, assign(socket, editing_collection: nil)}
  end

  def handle_event("update_collection", %{"id" => id, "collection" => params}, socket) do
    repo = socket.assigns.repo
    collection = repo.get!(Collection, id)

    changeset =
      Collection.changeset(collection, %{
        name: params["name"] || collection.name,
        description: params["description"]
      })

    case repo.update(changeset) do
      {:ok, _updated} ->
        {:noreply, socket |> assign(editing_collection: nil) |> load_data()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update: #{inspect(changeset.errors)}")}
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

    case repo.get(Collection, id) do
      nil ->
        {:noreply, assign(socket, confirm_delete_collection: nil)}

      collection ->
        repo.delete!(collection)
        {:noreply, socket |> assign(confirm_delete_collection: nil) |> load_data()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:collections}>
      <div class="arcana-collections">
        <h2>Collections</h2>
        <p class="arcana-tab-description">
          Organize documents into collections for scoped searches and better organization.
        </p>

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
                  <th>Documents</th>
                  <th style="width: 120px;">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for collection <- @collections do %>
                  <tr id={"collection-#{collection.name}"}>
                    <%= if @editing_collection && @editing_collection.id == collection.id do %>
                      <td colspan="4">
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
                      <td>
                        <%= collection.document_count %> <%= if collection.document_count == 1, do: "document", else: "documents" %>
                      </td>
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
                          <button
                            id={"edit-collection-#{collection.id}"}
                            class="arcana-btn"
                            phx-click="edit_collection"
                            phx-value-id={collection.id}
                          >
                            Edit
                          </button>
                          <button
                            id={"delete-collection-#{collection.id}"}
                            class="arcana-btn arcana-btn-danger"
                            phx-click="confirm_delete_collection"
                            phx-value-id={collection.id}
                          >
                            Delete
                          </button>
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
    </.dashboard_layout>
    """
  end
end
