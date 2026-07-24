defmodule Arcana.Config.Overrides do
  @moduledoc """
  Process-scoped configuration overrides for tests.

  Lets async tests override `:arcana` app env without mutating global state.
  Overrides are keyed by owner pid and are visible to the owner and to any
  process that carries the owner in its `$callers` or `$ancestors` chain —
  which covers LiveViews mounted via `Phoenix.LiveViewTest` and processes
  spawned through `Task`/`Task.Supervisor`.

  Disabled unless `enable/0` has been called (done in `test/test_helper.exs`),
  so production reads pay a single `:persistent_term` lookup and never touch
  ETS.
  """

  @table __MODULE__
  @flag {Arcana.Config, :overrides_enabled}

  @doc """
  Creates the override table and turns on override lookups.

  Must be called once, from a long-lived process (the test runner), since
  the calling process owns the ETS table.
  """
  def enable do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :persistent_term.put(@flag, true)
    :ok
  end

  @doc """
  Stores an override for `key` owned by the calling process.

  Re-putting the same key replaces the previous value. Storing `nil` is a
  real override: it shadows any globally configured value.
  """
  def put(key, value) do
    :ets.insert(@table, {{self(), key}, value})
    :ok
  end

  @doc """
  Removes every override owned by `pid`. Called from `on_exit`.
  """
  def delete_owned_by(pid) do
    :ets.match_delete(@table, {{pid, :_}, :_})
    :ok
  end

  @doc """
  Looks up an override for `key` visible to the calling process.

  Checks the caller itself, then its `$callers` chain, then `$ancestors`
  (resolving registered names). Returns `{:ok, value}` on the first hit —
  including `{:ok, nil}` — or `:error` when no override applies.
  """
  def fetch(key) do
    if enabled?() do
      lookup(candidate_pids(), key)
    else
      :error
    end
  end

  defp enabled?, do: :persistent_term.get(@flag, false)

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
