defmodule ArcanaWeb.BackgroundTaskTest do
  use ExUnit.Case, async: true

  test "delivers a tagged result" do
    assert {:ok, task} =
             ArcanaWeb.BackgroundTask.start(self(), :finished, fn -> {:ok, 42} end)

    assert_receive {:finished, run_ref, {:ok, 42}}
    assert run_ref == task.run_ref
    assert_receive {:DOWN, monitor_ref, :process, pid, :normal}
    assert monitor_ref == task.monitor_ref
    assert pid == task.pid
  end

  test "stops work when its owner exits" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, _task} =
          ArcanaWeb.BackgroundTask.start(self(), :finished, fn ->
            send(test_pid, {:worker, self()})
            Process.sleep(:infinity)
          end)

        Process.sleep(:infinity)
      end)

    assert_receive {:worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
  end

  test "turns worker exits into an error result" do
    assert {:ok, _task} =
             ArcanaWeb.BackgroundTask.start(self(), :finished, fn -> exit(:boom) end)

    assert_receive {:finished, _run_ref, {:error, message}}
    assert message =~ "boom"
  end

  test "runs cleanup once after normal completion" do
    test_pid = self()

    assert {:ok, _task} =
             ArcanaWeb.BackgroundTask.start(
               self(),
               :finished,
               fn ->
                 send(test_pid, {:worker, self()})
                 :done
               end,
               cleanup: fn -> send(test_pid, {:cleaned, self()}) end
             )

    assert_receive {:worker, worker}
    assert_receive {:finished, _run_ref, :done}
    assert_receive {:cleaned, guardian}
    refute Process.alive?(worker)
    refute_receive {:cleaned, ^guardian}
  end

  test "runs cleanup when the owner exits and the worker is killed" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, _task} =
          ArcanaWeb.BackgroundTask.start(
            self(),
            :finished,
            fn ->
              send(test_pid, {:worker_started, self()})
              Process.sleep(:infinity)
            end,
            cleanup: fn -> send(test_pid, :cleaned) end
          )

        Process.sleep(:infinity)
      end)

    assert_receive {:worker_started, worker}
    Process.exit(owner, :kill)
    assert_receive :cleaned
    refute Process.alive?(worker)
  end

  test "runs cleanup when the coordinator fails" do
    test_pid = self()

    assert {:ok, task} =
             ArcanaWeb.BackgroundTask.start(
               self(),
               :finished,
               fn ->
                 send(test_pid, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               cleanup: fn -> send(test_pid, :cleaned) end
             )

    assert_receive {:worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(task.pid, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive :cleaned
    assert_receive {:DOWN, monitor_ref, :process, pid, :killed}
    assert monitor_ref == task.monitor_ref
    assert pid == task.pid
  end

  test "does not start work or clean up before a registered worker dies" do
    test_pid = self()
    worker_state = :ets.new(:background_worker_state, [:set, :public])

    assert {:ok, task} =
             ArcanaWeb.BackgroundTask.start(
               self(),
               :finished,
               fn -> send(test_pid, :worker_ran) end,
               on_worker_registered: fn worker ->
                 :ets.insert(worker_state, {:worker, worker})
                 send(test_pid, {:worker_registered, worker})
                 Process.sleep(:infinity)
               end,
               cleanup: fn ->
                 [{:worker, worker}] = :ets.lookup(worker_state, :worker)
                 send(test_pid, {:cleaned, Process.alive?(worker)})
               end
             )

    assert_receive {:worker_registered, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(task.pid, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:cleaned, false}
    refute_receive :worker_ran
  end

  test "owner exit cancels a worker while the registration hook is blocked" do
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, task} =
          ArcanaWeb.BackgroundTask.start(
            self(),
            :finished,
            fn -> send(test_pid, :worker_ran) end,
            on_worker_registered: fn worker ->
              send(test_pid, {:worker_registered, worker})
              Process.sleep(:infinity)
            end,
            cleanup: fn -> send(test_pid, :cleaned) end
          )

        send(test_pid, {:task, task})
        Process.sleep(:infinity)
      end)

    assert_receive {:task, task}
    assert_receive {:worker_registered, worker}
    worker_ref = Process.monitor(worker)
    coordinator_ref = Process.monitor(task.pid)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
    assert_receive {:DOWN, ^coordinator_ref, :process, pid, :normal}
    assert pid == task.pid
    assert_receive :cleaned
    refute_receive :worker_ran
  end

  test "binds to the actual supervisor behind a registry name and stops with it" do
    test_pid = self()
    registry_name = ArcanaWeb.BackgroundTaskTest.SupervisorRegistry
    supervisor_name = {:via, Registry, {registry_name, :task_supervisor}}

    {:ok, registry} = Registry.start_link(keys: :unique, name: registry_name)
    Process.unlink(registry)

    on_exit(fn ->
      if Process.alive?(registry), do: Supervisor.stop(registry)
    end)

    {:ok, task_supervisor} = Task.Supervisor.start_link(name: supervisor_name)
    Process.unlink(task_supervisor)

    assert {:ok, task} =
             ArcanaWeb.BackgroundTask.start(
               self(),
               :finished,
               fn ->
                 send(test_pid, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               task_supervisor: supervisor_name,
               cleanup: fn -> send(test_pid, :cleaned) end
             )

    assert_receive {:worker, worker}
    worker_ref = Process.monitor(worker)
    Process.exit(task_supervisor, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, monitor_ref, :process, pid, :killed}, 1_000
    assert monitor_ref == task.monitor_ref
    assert pid == task.pid
    assert_receive :cleaned, 1_000
  end
end
