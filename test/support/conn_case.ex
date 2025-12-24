defmodule ArcanaWeb.ConnCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias Arcana.TestRepo, as: Repo

      @endpoint ArcanaWeb.Endpoint
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Arcana.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
