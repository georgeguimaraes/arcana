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
      scope path, alias: false, as: false do
        {session_name, session_opts, route_opts} =
          ArcanaWeb.Router.__options__(opts)

        import Phoenix.Router, only: [get: 4]
        import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]

        live_session session_name, session_opts do
          # Arcana assets
          get("/js-:hash", ArcanaWeb.Assets, :js, as: :arcana_asset)
          get("/css-:hash", ArcanaWeb.Assets, :css, as: :arcana_asset)

          live("/", ArcanaWeb.DashboardLive, :index, route_opts)
        end
      end
    end
  end

  defp expand_alias({:__aliases__, _, _} = alias, env),
    do: Macro.expand(alias, %{env | function: {:arcana_dashboard, 2}})

  defp expand_alias(other, _env), do: other

  @doc false
  def __options__(options) do
    live_socket_path = Keyword.get(options, :live_socket_path, "/live")
    repo = Keyword.get(options, :repo)

    session_args = [repo]

    {
      :arcana_dashboard,
      [
        session: {__MODULE__, :__session__, session_args},
        root_layout: {ArcanaWeb.Layouts, :root},
        on_mount: options[:on_mount] || nil
      ],
      [
        private: %{live_socket_path: live_socket_path},
        as: :arcana_dashboard
      ]
    }
  end

  @doc false
  def __session__(_conn, repo) do
    %{"repo" => repo || Application.get_env(:arcana, :repo)}
  end
end
