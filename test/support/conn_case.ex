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
    pid =
      Sandbox.start_owner!(Arcana.TestRepo,
        shared: not tags[:async],
        ownership_timeout: 60_000
      )

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Set up sandbox metadata for Phoenix.Ecto.SQL.Sandbox plug
    # This allows LiveView processes to share the test's database connection
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Arcana.TestRepo, pid)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header(
        "user-agent",
        Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata)
      )

    {:ok, conn: conn}
  end
end
