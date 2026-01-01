defmodule Arcana.TaskSupervisor do
  @moduledoc """
  Task supervisor for async operations in Arcana.

  Add to your application's supervision tree:

      children = [
        MyApp.Repo,
        Arcana.Embedder.Local,
        Arcana.TaskSupervisor
      ]

  This enables supervised async operations in the Arcana dashboard
  (evaluation runs, test case generation) with:
  - Graceful shutdown during deploys
  - Visibility in Observer/LiveDashboard
  - Proper crash logging with `$callers` metadata
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task.Supervisor, :start_link, [[name: __MODULE__]]},
      type: :supervisor
    }
  end
end
