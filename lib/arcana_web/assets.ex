defmodule ArcanaWeb.Assets do
  @moduledoc false

  @behaviour Plug

  # Bundle Phoenix LiveView JavaScript at compile time
  @external_resource phoenix_js = Application.app_dir(:phoenix, "priv/static/phoenix.min.js")
  @external_resource phoenix_html_js =
                       Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @external_resource live_view_js =
                       Application.app_dir(
                         :phoenix_live_view,
                         "priv/static/phoenix_live_view.min.js"
                       )

  @phoenix_js File.read!(phoenix_js)
  @phoenix_html_js File.read!(phoenix_html_js)
  @live_view_js File.read!(live_view_js)

  @app_js """
  let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
  liveSocket.connect()
  window.liveSocket = liveSocket
  """

  @js [@phoenix_js, @phoenix_html_js, @live_view_js, @app_js] |> Enum.join("\n")
  @js_hash :crypto.hash(:md5, @js) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @css ""
  @css_hash :crypto.hash(:md5, @css) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @doc """
  Returns the current hash for the given asset type.
  """
  def current_hash(:js), do: @js_hash
  def current_hash(:css), do: @css_hash

  @impl Plug
  def init(asset), do: asset

  @impl Plug
  def call(conn, asset) do
    {content, content_type} =
      case asset do
        :js -> {@js, "text/javascript"}
        :css -> {@css, "text/css"}
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", content_type)
    |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> Plug.Conn.delete_resp_header("x-frame-options")
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
    |> Plug.Conn.send_resp(200, content)
  end
end
