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

  # Mounting at the root would otherwise capture "/" as the prefix and turn
  # every href into a protocol-relative "//..." URL.
  defmodule RootRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import ArcanaWeb.Router

    arcana_dashboard("/", repo: Arcana.TestRepo)
  end

  test "root mount yields an empty prefix instead of a bare slash" do
    route = RootRouter |> Phoenix.Router.routes() |> Enum.find(&(&1.path == "/documents"))

    {_module, _action, _opts, %{extra: %{session: session_mfa}}} =
      route.metadata.phoenix_live_view

    assert session_mfa == {ArcanaWeb.Router, :__session__, [Arcana.TestRepo, ""]}
  end

  # Phoenix accepts a bare module for :on_mount, so prepending our Scope
  # hook must not build an improper list like [Scope | Module].
  test "__options__ wraps a single on_mount module into a proper list" do
    {_name, session_opts, _route_opts} =
      ArcanaWeb.Router.__options__([on_mount: SomeHook], "/arcana")

    assert session_opts[:on_mount] == [ArcanaWeb.Router.Scope, SomeHook]
  end

  describe ":collection option" do
    defmodule Access do
      def restricted(_conn), do: ["tenant-a", "tenant-b"]
      def one(_conn), do: "tenant-a"
      def open(_conn), do: :all
      def broken(_conn), do: {:ok, ["tenant-a"]}
      def mixed(_conn), do: ["tenant-a", :oops]
    end

    test "appends the MFA to the session args when given" do
      {_name, session_opts, _route_opts} =
        ArcanaWeb.Router.__options__(
          [repo: Arcana.TestRepo, collection: {Access, :restricted}],
          "/arcana"
        )

      assert session_opts[:session] ==
               {ArcanaWeb.Router, :__session__,
                [Arcana.TestRepo, "/arcana", {Access, :restricted}]}
    end

    test "rejects anything that is not a {module, function} tuple" do
      for bad <- [&String.length/1, "collection", {Access, :restricted, []}] do
        assert_raise ArgumentError, ~r/:collection must be a \{module, function\} tuple/, fn ->
          ArcanaWeb.Router.__options__([collection: bad], "/arcana")
        end
      end
    end

    test "rejects the removed plural option" do
      assert_raise ArgumentError, ~r/:collections is not supported/, fn ->
        ArcanaWeb.Router.__options__([collections: {Access, :restricted}], "/arcana")
      end
    end

    test "__session__/4 resolves the MFA into allowed_collections" do
      session =
        ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana", {Access, :restricted})

      assert session["allowed_collections"] == ["tenant-a", "tenant-b"]
      assert session["prefix"] == "/arcana"
      assert session["repo"] == Arcana.TestRepo
    end

    test "__session__/4 keeps :all unrestricted" do
      session = ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana", {Access, :open})

      assert session["allowed_collections"] == :all
    end

    test "__session__/4 normalizes one collection into the allowed list" do
      session = ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana", {Access, :one})

      assert session["allowed_collections"] == ["tenant-a"]
    end

    test "__session__/4 fails closed on invalid returns" do
      assert_raise ArgumentError, ~r/must return :all, a collection name/, fn ->
        ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana", {Access, :broken})
      end

      assert_raise ArgumentError, ~r/must return :all, a collection name/, fn ->
        ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana", {Access, :mixed})
      end
    end

    test "option absent keeps the session MFA and content unchanged" do
      {_name, session_opts, _route_opts} =
        ArcanaWeb.Router.__options__([repo: Arcana.TestRepo], "/arcana")

      assert session_opts[:session] ==
               {ArcanaWeb.Router, :__session__, [Arcana.TestRepo, "/arcana"]}

      session = ArcanaWeb.Router.__session__(nil, Arcana.TestRepo, "/arcana")
      refute Map.has_key?(session, "allowed_collections")
    end
  end
end
