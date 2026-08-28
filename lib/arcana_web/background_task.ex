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
    on_worker_registered = Keyword.get(opts, :on_worker_registered, fn _worker -> :ok end)
    task_supervisor = Keyword.get(opts, :task_supervisor, ArcanaWeb.TaskSupervisor)

    started =
      try do
        Task.Supervisor.start_child(task_supervisor, fn ->
          supervisor = task_supervisor_parent()
          Process.flag(:trap_exit, true)
          owner_ref = Process.monitor(owner)

          receive do
            {:background_start, ^run_ref, guardian} ->
              start_worker(
                owner,
                owner_ref,
                guardian,
                {callers, fun, on_worker_registered},
                supervisor,
                tag,
                run_ref
              )

            {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
              :ok

            {:EXIT, ^supervisor, reason} ->
              exit(reason)
          end
        end)
      catch
        :exit, reason -> {:error, reason}
      end

    case started do
      {:ok, coordinator} ->
        monitor_ref = Process.monitor(coordinator)
        guardian = start_cleanup_guardian(coordinator, cleanup)
        send(coordinator, {:background_start, run_ref, guardian})
        {:ok, %{pid: coordinator, monitor_ref: monitor_ref, run_ref: run_ref}}

      {:error, _reason} = error ->
        safely_cleanup(cleanup)
        error
    end
  end

  defp start_worker(
         owner,
         owner_ref,
         guardian,
         {callers, fun, on_worker_registered},
         supervisor,
         tag,
         run_ref
       ) do
    send(guardian, {:background_spawn_worker, self(), callers, fun})

    receive do
      {:background_worker_registered, ^guardian, worker} ->
        worker_ref = Process.monitor(worker)
        on_worker_registered.(worker)
        send(worker, {:background_worker_ready, guardian})
        await(owner, owner_ref, worker, worker_ref, supervisor, tag, run_ref)

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        :ok

      {:EXIT, ^supervisor, reason} ->
        exit(reason)
    end
  end

  defp await(owner, owner_ref, worker, worker_ref, supervisor, tag, run_ref) do
    receive do
      {:background_result, ^worker, result} ->
        Process.demonitor(owner_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
        send(owner, {tag, run_ref, result})
        :ok

      {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        await_worker_exit(worker, worker_ref)

      {:EXIT, ^supervisor, reason} ->
        Process.exit(worker, :kill)
        await_worker_exit(worker, worker_ref)
        exit(reason)

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        Process.demonitor(owner_ref, [:flush])
        send(owner, {tag, run_ref, {:error, Exception.format_exit(reason)}})
        :ok
    end
  end

  # The guardian is independent of the coordinator so cleanup still runs after
  # an untrappable exit. It waits for both coordinator and worker termination,
  # preventing cleanup from racing setup or in-flight request-scoped work.
  defp start_cleanup_guardian(coordinator, cleanup) do
    starter = self()

    guardian =
      spawn(fn ->
        coordinator_ref = Process.monitor(coordinator)
        send(starter, {:background_cleanup_ready, self()})
        await_worker_registration(coordinator, coordinator_ref, cleanup)
      end)

    receive do
      {:background_cleanup_ready, ^guardian} -> :ok
    end

    guardian
  end

  defp await_worker_registration(coordinator, coordinator_ref, cleanup) do
    receive do
      {:background_spawn_worker, ^coordinator, callers, fun} ->
        guardian = self()

        {worker, worker_ref} =
          spawn_monitor(fn ->
            receive do
              {:background_worker_ready, ^guardian} ->
                Process.put(:"$callers", callers)
                send(coordinator, {:background_result, self(), safely(fun)})
            end
          end)

        send(coordinator, {:background_worker_registered, guardian, worker})
        await_cleanup(coordinator, coordinator_ref, worker, worker_ref, false, false, cleanup)

      {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
        safely_cleanup(cleanup)
    end
  end

  defp await_cleanup(
         coordinator,
         coordinator_ref,
         worker,
         worker_ref,
         coordinator_down?,
         worker_down?,
         cleanup
       ) do
    if coordinator_down? and worker_down? do
      safely_cleanup(cleanup)
    else
      receive do
        {:DOWN, ^coordinator_ref, :process, ^coordinator, _reason} ->
          if not worker_down?, do: Process.exit(worker, :kill)

          await_cleanup(
            coordinator,
            coordinator_ref,
            worker,
            worker_ref,
            true,
            worker_down?,
            cleanup
          )

        {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
          await_cleanup(
            coordinator,
            coordinator_ref,
            worker,
            worker_ref,
            coordinator_down?,
            true,
            cleanup
          )
      end
    end
  end

  defp safely_cleanup(cleanup) do
    cleanup.()
  catch
    _kind, _reason -> :ok
  end

  defp await_worker_exit(worker, worker_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker, _reason} -> :ok
    end
  end

  defp task_supervisor_parent do
    {:links, [supervisor]} = Process.info(self(), :links)
    supervisor
  end

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, Exception.format_banner(kind, reason)}
  end
end
