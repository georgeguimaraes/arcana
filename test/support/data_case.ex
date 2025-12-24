defmodule Arcana.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Arcana.TestRepo, as: Repo
      import Ecto
      import Ecto.Query
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Arcana.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
