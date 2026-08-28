defmodule ArcanaWeb.BackgroundTask do
  @moduledoc false

  @doc """
  Runs dashboard work under ArcanaWeb.TaskSupervisor and ties its lifetime
  to the owning LiveView.

  The coordinator catches worker failures and always sends a tagged result.
  If the owner exits first, it kills the worker before the worker can keep
  using the owner's sandbox connection or other request-scoped resources.
  """
  def start(owner, tag, fun, opts \\ [])
      when is_pid(owner) and is_atom(tag) and is_function(fun, 0) and is_list(opts) do
    callers = [owner | Process.get(:"$callers", [])]
    run_ref = Keyword.get_lazy(opts, :run_ref, &make_ref/0)
    cleanup = Keyword.get(opts, :cleanup, fn -> :ok end)

    started =
      try do
        ArcanaWeb.TaskSupervisor.start_child(fn ->
          Process.flag(:trap_exit, true)
          owner_ref = Process.monitor(owner)

          receive do
            {:background_start, ^run_ref} ->
              coordinator = self()

              worker =
                spawn_link(fn ->
                  Process.put(:"$callers", callers)
                  send(coordinator, {:background_result, self(), safely(fun)})
                end)

              await(owner, owner_ref, worker, tag, run_ref)

            {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
              :ok
          end
        end)
      catch
        :exit, reason -> {:error, reason}
      end

    case started do
      {:ok, coordinator} ->
        monitor_ref = Process.monitor(coordinator)
        start_cleanup_guardian(owner, coordinator, cleanup)
        send(coordinator, {:background_start, run_ref})
        {:ok, %{pid: coordinator, monitor_ref: monitor_ref, run_ref: run_ref}}

      {:error, _reason} = error ->
        safely_cleanup(cleanup)
        error
    end
  end

  defp await(owner, owner_ref, worker, tag, run_ref) do
    receive do
      {:background_result, ^worker, result} ->
        Process.demonitor(owner_ref, [:flush])
        Process.unlink(worker)
        send(owner, {tag, run_ref, result})
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        await_worker_exit(worker)

      {:EXIT, ^worker, reason} ->
        Process.demonitor(owner_ref, [:flush])
        send(owner, {tag, run_ref, {:error, Exception.format_exit(reason)}})
        :ok
    end
  end

  # The guardian is deliberately independent of both owner and coordinator.
  # Whichever one disappears first ends the run and owns cleanup; this covers
  # both LiveView navigation and coordinator failure. It is ready before the
  # coordinator receives its start handshake, so even a zero-work task cannot
  # finish before cleanup is protected.
  defp start_cleanup_guardian(owner, coordinator, cleanup) do
    starter = self()

    guardian =
      spawn(fn ->
        owner_ref = Process.monitor(owner)
        coordinator_ref = Process.monitor(coordinator)
        send(starter, {:background_cleanup_ready, self()})

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} -> safely_cleanup(cleanup)
          {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} -> safely_cleanup(cleanup)
        end
      end)

    receive do
      {:background_cleanup_ready, ^guardian} -> :ok
    end
  end

  defp safely_cleanup(cleanup) do
    cleanup.()
  catch
    _kind, _reason -> :ok
  end

  defp await_worker_exit(worker) do
    receive do
      {:EXIT, ^worker, _reason} -> :ok
    end
  end

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end
end
