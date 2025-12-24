defmodule ArcanaWeb.Endpoint do
  @moduledoc """
  Test endpoint for Arcana dashboard.

  In production, the dashboard is mounted in the host application's endpoint.
  This endpoint is only used for testing.
  """
  use Phoenix.Endpoint, otp_app: :arcana

  @session_options [
    store: :cookie,
    key: "_arcana_key",
    signing_salt: "arcana_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(ArcanaWeb.Router)
end
