defmodule Arcana.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Arcana.TestRepo, as: Repo
      import Ecto
      import Ecto.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Arcana.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
