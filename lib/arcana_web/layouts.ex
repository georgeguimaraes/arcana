defmodule ArcanaWeb.Layouts do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Root layout for the Arcana dashboard.

  Renders a complete HTML document with isolated styles and bundled
  Phoenix LiveView JavaScript, making the dashboard self-contained.
  """
  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Arcana Dashboard</title>
        <style>
          /* Reset and isolate from host app styles */
          html, body {
            margin: 0;
            padding: 0;
            background: #f8fafc;
            min-height: 100vh;
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
          }
        </style>
      </head>
      <body>
        {@inner_content}
        <script defer src="/assets/js/app.js"></script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    {@inner_content}
    """
  end
end
