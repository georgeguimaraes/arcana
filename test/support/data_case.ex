defmodule Arcana.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Arcana.TestRepo, as: Repo
      import Ecto
      import Ecto.Query
      import Arcana.DataCase
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    pid =
      Sandbox.start_owner!(Arcana.TestRepo,
        shared: not tags[:async],
        ownership_timeout: 60_000
      )

    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
