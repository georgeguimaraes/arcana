defmodule Arcana.ConfigCase do
  @moduledoc """
  Test helper for process-scoped `:arcana` config overrides.

  `put_arcana_env/2` shadows a config key for the current test and every
  process it reaches through `$callers`/`$ancestors` (LiveViews mounted with
  `Phoenix.LiveViewTest`, Tasks). It never mutates global Application env,
  so it is safe in `async: true` tests.

  Per-test only: calling it from `setup_all` would register the override on
  the setup_all process, which is not in any test process's caller chain, so
  tests would silently not see it.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arcana.Config.Overrides

  def put_arcana_env(key, value) do
    owner = self()
    Overrides.put(key, value)
    on_exit(fn -> Overrides.delete_owned_by(owner) end)
    :ok
  end
end
