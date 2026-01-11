defmodule ArcanaWeb.Endpoint do
  @moduledoc """
  Test endpoint for Arcana LiveView testing.
  """
  use Phoenix.Endpoint, otp_app: :arcana

  @session_options [
    store: :cookie,
    key: "_arcana_key",
    signing_salt: "test_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Enable Ecto sandbox for LiveView tests - allows async tests to share
  # database connections properly between test process and LiveView process
  if Application.compile_env(:arcana, :sandbox) do
    plug(Phoenix.Ecto.SQL.Sandbox)
  end

  plug(Plug.Static,
    at: "/",
    from: :arcana,
    gzip: false
  )

  plug(Plug.Session, @session_options)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(:put_secret_key_base)
  plug(ArcanaWeb.TestRouter)

  defp put_secret_key_base(conn, _) do
    put_in(
      conn.secret_key_base,
      "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_purposes_only"
    )
  end
end
