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
       embedding_info: get_embedding_info()
     )
     |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
  end

  defp get_embedding_info do
    Arcana.Maintenance.embedding_info()
  rescue
    _ -> %{type: :unknown, dimensions: nil}
  end

  @impl true
  def handle_event("reembed", _params, socket) do
    repo = socket.assigns.repo
    parent = self()

    socket = assign(socket, reembed_running: true, reembed_progress: %{current: 0, total: 0})

    Task.start(fn ->
      progress_fn = fn current, total ->
        send(parent, {:reembed_progress, current, total})
      end

      result = Arcana.Maintenance.reembed(repo, batch_size: 50, progress: progress_fn)
      send(parent, {:reembed_complete, result})
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
          <h3>Re-embed All Chunks</h3>
          <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
            Re-embed all chunks using the current embedding configuration.
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
            <button
              phx-click="reembed"
              class="arcana-reembed-btn"
              style="background: #7c3aed; color: white; padding: 0.625rem 1.25rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer;"
            >
              Re-embed All Chunks
            </button>
          <% end %>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
