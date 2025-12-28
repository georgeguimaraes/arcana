defmodule ArcanaWeb.TestRouter do
  @moduledoc """
  Test router for Arcana dashboard testing.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import ArcanaWeb.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    arcana_dashboard("/arcana", repo: Arcana.TestRepo)
  end
end
