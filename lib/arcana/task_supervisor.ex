defmodule Arcana.TaskSupervisor do
  @moduledoc """
  Deprecated alias for `ArcanaWeb.TaskSupervisor`.

  The task supervisor only serves the dashboard's async operations, so it
  lives under the `ArcanaWeb` namespace now. This module keeps existing
  supervision trees working; update your children list to
  `ArcanaWeb.TaskSupervisor`.
  """

  require Logger

  @deprecated "Use ArcanaWeb.TaskSupervisor instead"
  def child_spec(opts) do
    Logger.warning(
      "Arcana.TaskSupervisor is deprecated, use ArcanaWeb.TaskSupervisor " <>
        "in your supervision tree instead."
    )

    ArcanaWeb.TaskSupervisor.child_spec(opts)
  end

  @deprecated "Use ArcanaWeb.TaskSupervisor.start_child/1 instead"
  defdelegate start_child(fun), to: ArcanaWeb.TaskSupervisor
end
