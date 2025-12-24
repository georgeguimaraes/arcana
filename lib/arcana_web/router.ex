defmodule ArcanaWeb.Router do
  @moduledoc """
  Router for the Arcana dashboard.

  Mount this in your Phoenix router:

      scope "/arcana" do
        pipe_through [:browser]
        forward "/", ArcanaWeb.Router
      end

  """
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", ArcanaWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
  end
end
