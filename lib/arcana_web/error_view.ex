# The dashboard is optional: everything under ArcanaWeb only compiles when
# Phoenix LiveView is available (see the optional deps in mix.exs).

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.ErrorView do
    @moduledoc false

    def render(template, _assigns) do
      Phoenix.Controller.status_message_from_template(template)
    end
  end
end
