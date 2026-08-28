defmodule ArcanaWeb.TaskSupervisorTest do
  @moduledoc """
  Pins which halves of the `Arcana.TaskSupervisor` rename work.

  Listing the old module in a supervision tree goes through its `child_spec/1`
  and works. `Task.Supervisor.start_child(Arcana.TaskSupervisor, fun)` resolves
  that atom as a registered process name, and a process may hold only one
  registered name, so it cannot be shimmed and exits `:noproc`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  test "start_child works under the current registered name" do
    parent = self()

    assert {:ok, _} =
             Task.Supervisor.start_child(ArcanaWeb.TaskSupervisor, fn ->
               send(parent, :ran_via_current_name)
             end)

    assert_receive :ran_via_current_name, 1_000
  end

  test "the deprecated module's own helpers still delegate" do
    parent = self()

    assert {:ok, _} =
             :erlang.apply(Arcana.TaskSupervisor, :start_child, [
               fn -> send(parent, :ran_via_shim) end
             ])

    assert_receive :ran_via_shim, 1_000
  end

  test "the old module's child_spec still starts the supervisor under the new name" do
    parent = self()

    log =
      capture_log(fn ->
        send(parent, {:spec, :erlang.apply(Arcana.TaskSupervisor, :child_spec, [[]])})
      end)

    assert_receive {:spec, spec}

    assert spec.id == ArcanaWeb.TaskSupervisor
    assert {Task.Supervisor, :start_link, [[name: ArcanaWeb.TaskSupervisor]]} = spec.start
    assert log =~ "Arcana.TaskSupervisor is deprecated"
  end

  test "the legacy name holds no process, so start_child on it exits" do
    # This is the half that cannot be shimmed. A process may hold exactly one
    # registered name, so the supervisor cannot also answer to the old atom:
    #
    #   Process.register(pid, Arcana.TaskSupervisor)
    #   ** (ArgumentError) ... it has already been given another name
    #
    # The deprecation warning says so rather than implying the old name works.
    assert Process.whereis(Arcana.TaskSupervisor) == nil

    assert catch_exit(Task.Supervisor.start_child(Arcana.TaskSupervisor, fn -> :ok end))
  end

  test "one process really cannot hold two names" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    Process.register(pid, :arcana_alias_probe_one)

    assert_raise ArgumentError, fn -> Process.register(pid, :arcana_alias_probe_two) end
    assert Process.whereis(:arcana_alias_probe_two) == nil
  end
end
