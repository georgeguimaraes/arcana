defmodule ArcanaWeb.TestRouter do
  @moduledoc """
  Test router for Arcana dashboard testing.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import ArcanaWeb.Router

  defmodule Allowed do
    @moduledoc false

    # Collections MFA for the /scoped dashboard below. Reads the allowed
    # list from the conn's session so each test can set its own restriction
    # via Plug.Test.init_test_session/2 — per-conn state, async-safe.
    def for_conn(conn) do
      Plug.Conn.get_session(conn, :allowed_collections) || :all
    end
  end

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

  scope "/" do
    pipe_through(:browser)

    arcana_dashboard("/scoped",
      repo: Arcana.TestRepo,
      live_session_name: :arcana_dashboard_scoped,
      collections: {ArcanaWeb.TestRouter.Allowed, :for_conn}
    )
  end
end
