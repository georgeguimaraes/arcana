# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Without
# phoenix, a stub arcana_dashboard/2 raises with instructions at
# compile time.
if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.Router do
    @moduledoc """
    Provides LiveView routing for the Arcana dashboard.

    ## Usage

    Add to your router:

        import ArcanaWeb.Router

        scope "/" do
          pipe_through :browser

          arcana_dashboard "/arcana"
        end

    ## Options

      * `:live_socket_path` - The path to the LiveView socket. Defaults to `"/live"`.

      * `:repo` - The Ecto repo to use for Arcana operations. If not provided,
        falls back to `Application.get_env(:arcana, :repo)`.

      * `:on_mount` - Optional list of `Phoenix.LiveView.on_mount/1` callbacks
        to add to the dashboard's live_session.

      * `:live_session_name` - The name of the dashboard's live_session.
        Defaults to `:arcana_dashboard`. Phoenix requires live_session names
        to be unique within a router, so mounting the dashboard more than
        once (say, a superuser dashboard plus a scoped one) needs a distinct
        name for each extra mount.

      * `:collection` - Optional `{module, function}` pair that scopes the
        dashboard to a subset of collections. The function receives the
        `%Plug.Conn{}` of the page request and must return `:all`, one collection
        name, a list of names, or `[]`. Every dashboard surface
        (listings, search, ask, ingest, evaluation, maintenance, stats) is
        limited to those collections, and events naming any other collection
        are rejected server-side. A plain `{module, function}` tuple is
        required (not a function capture) so the route metadata stays
        serializable. See "Scoping collections" for when the decision is
        re-evaluated.

    ## Example with options

        arcana_dashboard "/arcana",
          repo: MyApp.Repo,
          on_mount: [MyAppWeb.Auth]

    ## Scoping collections

        arcana_dashboard "/arcana",
          collection: {MyAppWeb.ArcanaAccess, :allowed_collections}

        defmodule MyAppWeb.ArcanaAccess do
          def allowed_collections(conn) do
            case conn.assigns.current_user do
              %{admin: true} -> :all
              %{tenant: tenant} -> ["\#{tenant}-docs"]
            end
          end
        end

    ### When the decision is made

    The function runs while the page request is being served, and its result
    is **snapshotted into the LiveView session**: Phoenix signs it into the
    rendered `data-phx-session` payload, which stays valid for the session's
    max age (14 days by default). The websocket connect, every reconnect,
    and every `live_patch`/`live_redirect` inside the dashboard read back
    that snapshot instead of calling the function again. Only a full page
    request re-runs it.

    So narrowing a user's permissions does not narrow an already-rendered
    dashboard. Until the user loads a fresh page, they keep the scope they
    mounted with. The `on_mount` hook cannot close that gap on its own —
    there is no `%Plug.Conn{}` in a LiveView mount to re-resolve from.

    The mitigation is to cut the socket when permissions change. Set a
    `live_socket_id` per user in your session (Phoenix's
    `put_session(conn, :live_socket_id, "users_socket:\#{user.id}")`), then
    broadcast a disconnect when their access changes:

        MyAppWeb.Endpoint.broadcast("users_socket:\#{user.id}", "disconnect", %{})

    The client reconnects through a full request, which re-runs the MFA with
    the current `%Plug.Conn{}`. Pair it with a short session max age if you
    need a hard upper bound on how long a stale scope can live.

    """

    @doc """
    Defines an Arcana dashboard route.

    It expects the `path` the dashboard will be mounted at
    and a set of options.
    """
    defmacro arcana_dashboard(path, opts \\ []) do
      opts =
        if Macro.quoted_literal?(opts) do
          Macro.prewalk(opts, &expand_alias(&1, __CALLER__))
        else
          opts
        end

      quote bind_quoted: binding() do
        # Full mount prefix including enclosing scopes, e.g. "/admin/arcana"
        # for `scope "/admin" do arcana_dashboard "/arcana" end`. Captured
        # here so links and asset hrefs don't assume a "/arcana" mount. The
        # trailing slash is trimmed so a root mount ("/") yields an empty
        # prefix instead of turning hrefs into protocol-relative "//..." URLs.
        prefix = String.trim_trailing(Phoenix.Router.scoped_path(__MODULE__, path), "/")

        scope path, alias: false, as: false do
          {session_name, session_opts, route_opts} =
            ArcanaWeb.Router.__options__(opts, prefix)

          import Phoenix.Router, only: [get: 4]
          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

          live_session session_name, session_opts do
            # Arcana assets
            get("/js-:hash", ArcanaWeb.Assets, :js, as: :arcana_asset)
            get("/css-:hash", ArcanaWeb.Assets, :css, as: :arcana_asset)

            # Main dashboard (redirects to documents)
            live("/", ArcanaWeb.DashboardLive, :index, route_opts)

            # Separate pages for each tab
            live("/documents", ArcanaWeb.DocumentsLive, :index, route_opts)
            live("/collections", ArcanaWeb.CollectionsLive, :index, route_opts)
            live("/graph", ArcanaWeb.GraphLive, :index, route_opts)
            live("/search", ArcanaWeb.SearchLive, :index, route_opts)
            live("/ask", ArcanaWeb.AskLive, :index, route_opts)
            live("/ask/:sub_tab", ArcanaWeb.AskLive, :index, route_opts)
            live("/evaluation", ArcanaWeb.EvaluationLive, :index, route_opts)
            live("/maintenance", ArcanaWeb.MaintenanceLive, :index, route_opts)
            live("/info", ArcanaWeb.InfoLive, :index, route_opts)
          end
        end
      end
    end

    defp expand_alias({:__aliases__, _, _} = alias, env),
      do: Macro.expand(alias, %{env | function: {:arcana_dashboard, 2}})

    defp expand_alias(other, _env), do: other

    @doc false
    def __options__(options, prefix) do
      live_socket_path = Keyword.get(options, :live_socket_path, "/live")
      repo = Keyword.get(options, :repo)
      collection = options |> Keyword.get(:collection) |> validate_collection_option!()

      if Keyword.has_key?(options, :collections) do
        raise ArgumentError,
              ":collections is not supported, pass the dashboard scope through :collection"
      end

      # The collection spec is only appended when given, so dashboards
      # without the option keep the exact session MFA they had before.
      session_args = if collection, do: [repo, prefix, collection], else: [repo, prefix]

      {
        Keyword.get(options, :live_session_name, :arcana_dashboard),
        [
          session: {__MODULE__, :__session__, session_args},
          root_layout: {ArcanaWeb.Layouts, :root},
          on_mount: [ArcanaWeb.Router.Scope | List.wrap(options[:on_mount])]
        ],
        [
          private: %{live_socket_path: live_socket_path},
          as: :arcana_dashboard
        ]
      }
    end

    defp validate_collection_option!(nil), do: nil

    defp validate_collection_option!({mod, fun} = spec) when is_atom(mod) and is_atom(fun),
      do: spec

    defp validate_collection_option!(other) do
      raise ArgumentError,
            ":collection must be a {module, function} tuple where the function " <>
              "accepts a Plug.Conn and returns a collection scope, " <>
              "got: #{inspect(other)}"
    end

    @doc false
    def __session__(_conn, repo, prefix) do
      %{
        "repo" => repo || Arcana.Config.get_env(:repo),
        "prefix" => prefix
      }
    end

    @doc false
    def __session__(conn, repo, prefix, collections_spec) do
      conn
      |> __session__(repo, prefix)
      |> Map.put("allowed_collections", resolve_allowed_collections(conn, collections_spec))
    end

    defp resolve_allowed_collections(conn, {mod, fun}) do
      input = apply(mod, fun, [conn])

      case Arcana.CollectionScope.normalize(input) do
        {:ok, :all} ->
          :all

        {:ok, {:only, names}} ->
          names

        {:error, _reason} ->
          raise ArgumentError,
                "#{inspect(mod)}.#{fun}/1 must return :all, a collection name, " <>
                  "or a list of collection names, got: #{inspect(input)}"
      end
    end
  end

  defmodule ArcanaWeb.Router.Scope do
    @moduledoc false

    # Assigns the dashboard's mount prefix (e.g. "/admin/arcana") to every
    # dashboard LiveView so links and asset hrefs are built from the actual
    # mount point instead of assuming "/arcana", plus the allowed collections
    # resolved by the router's :collection MFA (:all when the option is
    # absent). An empty list is a valid restriction and must not collapse to
    # :all, so only a missing session key falls back.
    #
    # The list is read back from the signed session, not re-resolved: a
    # LiveView mount has no %Plug.Conn{} to hand the MFA. See the
    # "Scoping collections" section of ArcanaWeb.Router for what that means
    # for permission changes mid-session, and how to force a re-resolve.
    def on_mount(:default, _params, session, socket) do
      {:cont,
       Phoenix.Component.assign(socket,
         prefix: session["prefix"] || "/arcana",
         allowed_collections: session["allowed_collections"] || :all
       )}
    end
  end
else
  defmodule ArcanaWeb.Router do
    @moduledoc """
    Stub for when Phoenix LiveView is not available.

    The Arcana dashboard is optional; mounting it requires the phoenix
    dependencies. See `arcana_dashboard/2` for the requirements.
    """

    @doc """
    Raises at compile time: the dashboard requires Phoenix LiveView.
    """
    defmacro arcana_dashboard(_path, _opts \\ []) do
      raise """
      arcana_dashboard/2 requires Phoenix LiveView, which is an optional
      dependency of arcana.

      Add it to your dependencies to use the dashboard:

          {:phoenix_live_view, "~> 1.0"},
          {:phoenix_html, "~> 4.1"}

      Then recompile arcana:

          mix deps.compile arcana --force
      """
    end
  end
end
