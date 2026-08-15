defmodule ArcanaWeb.RouterTest do
  use ExUnit.Case, async: true

  # arcana_dashboard mounted inside an enclosing scope: everything must be
  # generated relative to /admin/arcana, and the live session must carry
  # the prefix so links and asset hrefs don't assume /arcana (issue #101).
  defmodule NestedRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import ArcanaWeb.Router

    scope "/admin" do
      arcana_dashboard("/arcana", repo: Arcana.TestRepo)
    end
  end

  test "routes are generated under the enclosing scope" do
    paths = NestedRouter |> Phoenix.Router.routes() |> Enum.map(& &1.path)

    assert "/admin/arcana" in paths
    assert "/admin/arcana/documents" in paths
    assert "/admin/arcana/css-:hash" in paths
    assert "/admin/arcana/js-:hash" in paths
  end

  test "live session carries the full mount prefix" do
    route = NestedRouter |> Phoenix.Router.routes() |> Enum.find(&(&1.path == "/admin/arcana"))

    {_module, _action, _opts, %{extra: %{session: session_mfa}}} =
      route.metadata.phoenix_live_view

    assert session_mfa == {ArcanaWeb.Router, :__session__, [Arcana.TestRepo, "/admin/arcana"]}
  end

  test "__session__ exposes the prefix to LiveViews" do
    session = ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/admin/arcana")

    assert session["prefix"] == "/admin/arcana"
    assert session["repo"] == Arcana.TestRepo
  end
end
