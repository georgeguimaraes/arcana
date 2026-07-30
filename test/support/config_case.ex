defmodule Arcana.ConfigCase do
  @moduledoc """
  Process-scoped `:arcana` config overrides for async tests.

  `put_arcana_env/2` shadows a config key for the current test and every
  process it reaches through `$callers`/`$ancestors` (LiveViews mounted with
  `Phoenix.LiveViewTest`, Tasks). It never mutates global Application env,
  so it is safe in `async: true` tests.

  Backed by an ETS table installed into `Arcana.Config.get_env/2` via
  `Arcana.Config.install_env_reader/1` in `test/test_helper.exs` — the
  library itself carries only that seam, none of this machinery.

  Per-test only: calling `put_arcana_env/2` from `setup_all` would register
  the override on the setup_all process, which is not in any test process's
  caller chain, so tests would silently not see it.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @table __MODULE__

  @doc """
  Creates the override table and installs the reader into `Arcana.Config`.

  Must be called once, from a long-lived process (the test runner), since
  the calling process owns the ETS table.
  """
  def enable do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    Arcana.Config.install_env_reader(&read_env/2)
    :ok
  end

  @doc """
  Shadows `key` for the current test (and processes it spawns or mounts).

  Re-putting the same key replaces the previous value. Storing `nil` is a
  real override: it shadows any globally configured value. Cleanup is
  registered automatically via `on_exit`.
  """
  def put_arcana_env(key, value) do
    owner = self()
    :ets.insert(@table, {{owner, key}, value})
    on_exit(fn -> :ets.match_delete(@table, {{owner, :_}, :_}) end)
    :ok
  end

  @doc false
  def read_env(key, default) do
    case lookup(candidate_pids(), key) do
      {:ok, value} -> value
      :error -> Application.get_env(:arcana, key, default)
    end
  end

  defp candidate_pids do
    callers = Process.get(:"$callers", [])
    ancestors = Process.get(:"$ancestors", [])

    [self() | callers ++ ancestors]
    |> Enum.map(fn
      pid when is_pid(pid) -> pid
      name when is_atom(name) -> Process.whereis(name)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp lookup([], _key), do: :error

  defp lookup([pid | rest], key) do
    case :ets.lookup(@table, {pid, key}) do
      [{_owner_key, value}] -> {:ok, value}
      [] -> lookup(rest, key)
    end
  end
end
