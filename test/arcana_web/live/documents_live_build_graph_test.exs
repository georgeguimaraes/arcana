defmodule ArcanaWeb.DocumentsLiveBuildGraphTest do
  @moduledoc """
  Build Graph, when the build does not succeed.

  The button starts a task through `ArcanaWeb.TaskSupervisor.start_child/1`,
  which is supervised but *not* linked to the LiveView. So a task that dies
  takes its `{:graph_complete, _}` message with it, and `graph_indexing` stays
  `true`: the button sits on "Building..." forever with nothing on screen
  saying why. `handle_info/2` already had an `{:error, reason}` branch that
  cleared the spinner correctly. Nothing ever reached it.

  Two ways in, and they need opposite setups, hence the two describe blocks:
  the schema being absent (config enables the graph, the migration never ran)
  and the build itself failing on a database where the schema is fine.
  """
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Arcana.ConfigCase, only: [put_arcana_env: 2]

  alias Ecto.Adapters.SQL

  defp open_document(conn, doc), do: live(conn, "/arcana/documents?doc=#{doc.id}")

  defp seed_document do
    # Ingest before enabling the graph: with the graph on, Arcana.ingest/2
    # builds one too, so seeding afterwards fails in setup for the very
    # reason these tests are about.
    {:ok, doc} = Arcana.ingest("Elixir runs on the BEAM virtual machine.", repo: Repo)
    doc
  end

  describe "the graph schema was never migrated" do
    setup do
      doc = seed_document()
      put_arcana_env(:graph, enabled: true)

      SQL.query!(
        Repo,
        "ALTER TABLE arcana_graph_entities RENAME TO arcana_graph_entities_hidden",
        []
      )

      %{doc: doc}
    end

    test "precondition: the graph reads as enabled but not installed" do
      assert Arcana.Graph.enabled?(), "the Build Graph button renders off this flag"
      refute Arcana.Graph.installed?(Repo), "and the schema is what is missing"
    end

    test "clicking Build Graph names the migration to run", %{conn: conn, doc: doc} do
      {:ok, view, _html} = open_document(conn, doc)

      html = render_hook(view, "build_graph", %{})

      assert html =~ "GraphRAG is not installed"
      assert html =~ "Arcana.Graph.Migration.up"
      assert Process.alive?(view.pid)
    end

    test "and the spinner is never switched on in the first place", %{conn: conn, doc: doc} do
      # The actual regression. The flash is the nice part; what broke the page
      # was graph_indexing going true with nothing left alive to clear it.
      {:ok, view, _html} = open_document(conn, doc)

      render_hook(view, "build_graph", %{})

      refute render(view) =~ "Building...",
             "graph_indexing must not be left on after a refused build"
    end
  end

  describe "the build fails on a database that has the schema" do
    setup do
      %{doc: seed_document()}
    end

    test "an extractor that exits does not strand the spinner", %{conn: conn, doc: doc} do
      # `rescue` does not catch an exit, and a GenServer.call timeout exits -
      # which is exactly why Arcana.Ingest uses `catch kind, reason` at
      # build_graph_or_fail_document/5. A rescue here left an exiting
      # extractor hanging the button the same way a missing table did.
      put_arcana_env(:graph,
        enabled: true,
        entity_extractor: fn _text, _opts -> exit(:simulated_timeout) end
      )

      {:ok, view, _html} = open_document(conn, doc)
      render_hook(view, "build_graph", %{})

      assert eventually(fn -> not (render(view) =~ "Building...") end),
             "an exit inside the task left graph_indexing on"

      assert Process.alive?(view.pid)
    end

    test "an extractor that raises does not strand the spinner", %{conn: conn, doc: doc} do
      put_arcana_env(:graph,
        enabled: true,
        entity_extractor: fn _text, _opts -> raise "extractor exploded" end
      )

      {:ok, view, _html} = open_document(conn, doc)
      render_hook(view, "build_graph", %{})

      assert eventually(fn -> not (render(view) =~ "Building...") end),
             "a raise inside the task left graph_indexing on"

      assert Process.alive?(view.pid)
    end
  end

  # The task is asynchronous, so poll rather than sleep a fixed guess: a fixed
  # sleep is either flaky on a loaded machine or slower than it needs to be.
  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts <= 1 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
