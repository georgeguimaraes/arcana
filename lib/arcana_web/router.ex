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

    ## Example with options

        arcana_dashboard "/arcana",
          repo: MyApp.Repo,
          on_mount: [MyAppWeb.Auth]

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

      session_args = [repo, prefix]

      {
        :arcana_dashboard,
        [
          session: {__MODULE__, :__session__, session_args},
          root_layout: {ArcanaWeb.Layouts, :root},
          on_mount: [ArcanaWeb.Router.Prefix | List.wrap(options[:on_mount])]
        ],
        [
          private: %{live_socket_path: live_socket_path},
          as: :arcana_dashboard
        ]
      }
    end

    @doc false
    def __session__(_conn, repo, prefix) do
      %{
        "repo" => repo || Arcana.Config.get_env(:repo),
        "prefix" => prefix
      }
    end
  end

  defmodule ArcanaWeb.Router.Prefix do
    @moduledoc false

    # Assigns the dashboard's mount prefix (e.g. "/admin/arcana") to every
    # dashboard LiveView so links and asset hrefs are built from the actual
    # mount point instead of assuming "/arcana".
    def on_mount(:default, _params, session, socket) do
      {:cont, Phoenix.Component.assign(socket, :prefix, session["prefix"] || "/arcana")}
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
