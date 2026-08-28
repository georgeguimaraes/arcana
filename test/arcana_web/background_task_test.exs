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
               fn -> :done end,
               cleanup: fn -> send(test_pid, :cleaned) end
             )

    assert_receive {:finished, _run_ref, :done}
    assert_receive :cleaned
    refute_receive :cleaned
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
              send(test_pid, :worker_started)
              Process.sleep(:infinity)
            end,
            cleanup: fn -> send(test_pid, :cleaned) end
          )

        Process.sleep(:infinity)
      end)

    assert_receive :worker_started
    Process.exit(owner, :kill)
    assert_receive :cleaned
  end

  test "runs cleanup when the coordinator fails" do
    test_pid = self()

    assert {:ok, task} =
             ArcanaWeb.BackgroundTask.start(
               self(),
               :finished,
               fn -> Process.sleep(:infinity) end,
               cleanup: fn -> send(test_pid, :cleaned) end
             )

    Process.exit(task.pid, :kill)
    assert_receive :cleaned
    assert_receive {:DOWN, monitor_ref, :process, pid, :killed}
    assert monitor_ref == task.monitor_ref
    assert pid == task.pid
  end
end
