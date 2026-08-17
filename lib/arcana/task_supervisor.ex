defmodule Arcana.TaskSupervisor do
  @moduledoc """
  Deprecated alias for `ArcanaWeb.TaskSupervisor`.

  The task supervisor only serves the dashboard's async operations, so it
  lives under the `ArcanaWeb` namespace now. Update your children list to
  `ArcanaWeb.TaskSupervisor`.

  Two things carried the old name, and both keep working for the deprecation
  window:

    * listing this module in a supervision tree, via `child_spec/1` here
    * `Task.Supervisor.start_child(Arcana.TaskSupervisor, fun)`, which
      resolves the atom as a registered process name rather than calling
      anything on this module

  The second **does not work and cannot be made to**. A process may hold only
  one registered name, so the supervisor cannot answer to this one as well:

      Process.register(pid, Arcana.TaskSupervisor)
      ** (ArgumentError) could not register #PID<...> ... it has already been
         given another name

  Update those call sites to `ArcanaWeb.TaskSupervisor`. This module going
  away in a future release only affects the supervision-tree usage.
  """

  require Logger

  @deprecated "Use ArcanaWeb.TaskSupervisor instead"
  def child_spec(opts) do
    Logger.warning(
      "Arcana.TaskSupervisor is deprecated, use ArcanaWeb.TaskSupervisor. " <>
        "The registered process name changed too, and that part is not " <>
        "shimmed: a process may hold only one registered name, so " <>
        "Task.Supervisor.start_child(Arcana.TaskSupervisor, fun) exits with " <>
        ":noproc. Update those call sites to ArcanaWeb.TaskSupervisor."
    )

    ArcanaWeb.TaskSupervisor.child_spec(opts)
  end

  @deprecated "Use ArcanaWeb.TaskSupervisor.start_child/1 instead"
  defdelegate start_child(fun), to: ArcanaWeb.TaskSupervisor
end
