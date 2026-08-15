# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Only
# ArcanaWeb.TaskSupervisor is phoenix-free and stays available.

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.ErrorView do
    @moduledoc false

    def render(template, _assigns) do
      Phoenix.Controller.status_message_from_template(template)
    end
  end
end
