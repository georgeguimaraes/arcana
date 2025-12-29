defmodule ArcanaWeb.DashboardLive do
  @moduledoc """
  Redirects to the Documents page.

  This module previously contained the monolithic dashboard with tab switching.
  It has been replaced by separate LiveView pages for each tab:

  - `/documents` - ArcanaWeb.DocumentsLive
  - `/collections` - ArcanaWeb.CollectionsLive
  - `/search` - ArcanaWeb.SearchLive
  - `/ask` - ArcanaWeb.AskLive
  - `/evaluation` - ArcanaWeb.EvaluationLive
  - `/maintenance` - ArcanaWeb.MaintenanceLive
  - `/info` - ArcanaWeb.InfoLive
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket, layout: false}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <script>window.location.href = window.location.pathname + "/documents";</script>
    """
  end
end
