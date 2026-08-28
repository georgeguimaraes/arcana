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

  alias Arcana.Collection
  alias Ecto.Adapters.SQL

  defp open_document(conn, doc), do: live(conn, "/arcana/documents?doc=#{doc.id}")

  # render_click through the element rather than render_hook: it goes through
  # the rendered button, so it also proves the button exists and is not
  # disabled. render_hook fires whether or not anything is on screen.
  defp click_build_graph(view) do
    view |> element("button[phx-click='build_graph']") |> render_click()
  end

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

      html = click_build_graph(view)

      assert html =~ "GraphRAG is not installed"
      assert html =~ "Arcana.Graph.Migration.up"
      assert Process.alive?(view.pid)
    end

    test "and the spinner is never switched on in the first place", %{conn: conn, doc: doc} do
      # The actual regression. The flash is the nice part; what broke the page
      # was graph_indexing going true with nothing left alive to clear it.
      {:ok, view, _html} = open_document(conn, doc)

      click_build_graph(view)

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
      click_build_graph(view)

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
      click_build_graph(view)

      assert eventually(fn -> not (render(view) =~ "Building...") end),
             "a raise inside the task left graph_indexing on"

      assert Process.alive?(view.pid)
    end

    test "a killed task does not strand the spinner either", %{conn: conn, doc: doc} do
      # No try/catch can see this one: :kill does not run the task's code. The
      # monitor is what clears the spinner, which is the difference between
      # "we handled the failures we listed" and "the spinner always clears".
      test_pid = self()

      put_arcana_env(:graph,
        enabled: true,
        entity_extractor: fn _text, _opts ->
          send(test_pid, {:building, self()})
          Process.sleep(:infinity)
        end
      )

      {:ok, view, _html} = open_document(conn, doc)
      click_build_graph(view)

      assert render(view) =~ "Building...", "precondition: the build is in flight"

      assert_receive {:building, worker}, 5000
      Process.exit(worker, :kill)

      assert eventually(fn -> not (render(view) =~ "Building...") end),
             "a killed task left graph_indexing on"

      assert Process.alive?(view.pid)
    end

    test "an unrelated process dying does not clear the spinner", %{conn: conn, doc: doc} do
      # The DOWN clause used to match any ref, so any other monitor firing
      # during a build would clear the spinner and flash a graph error for a
      # process that had nothing to do with the graph.
      test_pid = self()

      put_arcana_env(:graph,
        enabled: true,
        entity_extractor: fn _text, _opts ->
          send(test_pid, {:building, self()})
          Process.sleep(:infinity)
        end
      )

      {:ok, view, _html} = open_document(conn, doc)
      click_build_graph(view)
      assert_receive {:building, worker}, 5000
      assert render(view) =~ "Building...", "precondition: the build is in flight"

      # Both of these sleep forever, and the worker holds a sandbox connection
      # from the shared task supervisor, so leaving them running leaks into the
      # rest of the suite.
      stranger = spawn(fn -> Process.sleep(:infinity) end)

      on_exit(fn ->
        Process.exit(worker, :kill)
        Process.exit(stranger, :kill)
      end)

      send(view.pid, {:DOWN, make_ref(), :process, stranger, :killed})

      assert render(view) =~ "Building...",
             "someone else's DOWN must leave the build alone"

      refute render(view) =~ "Graph build stopped"
    end
  end

  describe "a build already in flight" do
    setup do
      %{doc: seed_document()}
    end

    test "a second build_graph is ignored rather than displacing the first", %{
      conn: conn,
      doc: doc
    } do
      # The second start overwrote graph_task_ref, so the first completion
      # demonitored the second task and cleared the spinner while it ran on.
      test_pid = self()

      put_arcana_env(:graph,
        enabled: true,
        entity_extractor: fn _text, _opts ->
          send(test_pid, {:building, self()})
          Process.sleep(:infinity)
        end
      )

      {:ok, view, _html} = open_document(conn, doc)
      click_build_graph(view)
      assert_receive {:building, worker}, 5000
      on_exit(fn -> Process.exit(worker, :kill) end)

      # The button is disabled at this point, so go straight at the handler the
      # way a raced or forged event would.
      render_hook(view, "build_graph", %{})

      refute_receive {:building, _second}, 500

      assert render(view) =~ "Building...",
             "the first build must still be running"
    end
  end

  describe "the open document leaves the allowed scope" do
    test "the build reauthorizes the document and chunks before starting", %{conn: conn} do
      {:ok, doc} =
        Arcana.ingest("Scoped graph content", repo: Repo, collection: "tenant-a")

      put_arcana_env(:graph, enabled: true)

      conn = Plug.Test.init_test_session(conn, allowed_collections: ["tenant-a"])
      {:ok, view, _html} = live(conn, "/scoped/documents?doc=#{doc.id}")

      collection = Repo.get_by!(Collection, name: "tenant-a")
      Repo.update!(Collection.changeset(collection, %{name: "renamed-away"}))

      html = click_build_graph(view)

      assert html =~ "This document is no longer available."
      refute html =~ "Building..."
    end
  end

  describe "the build task cannot be started" do
    setup do
      %{doc: seed_document()}
    end

    test "a supervisor that refuses does not take the page down", %{conn: conn, doc: doc} do
      # Matching {:ok, task_pid} crashed the LiveView when start_child returned
      # an error tuple, which is a worse outcome than the hang being fixed.
      put_arcana_env(:graph, enabled: true)

      {:ok, view, _html} = open_document(conn, doc)

      # max_children: 0 makes the next start_child return {:error, :max_children}
      # without having to reach into the supervisor's internals.
      :ok = restrict_task_supervisor()

      html = click_build_graph(view)

      assert Process.alive?(view.pid), "a refused start must not crash the page"
      assert html =~ "Could not start the graph build"
      refute html =~ "Building..."
    end
  end

  # Flip ArcanaWeb.TaskSupervisor to max_children: 0 for the rest of the test.
  # It is a named supervisor shared by the app, so put it back afterwards.
  defp restrict_task_supervisor do
    original = :sys.get_state(ArcanaWeb.TaskSupervisor)
    on_exit(fn -> :sys.replace_state(ArcanaWeb.TaskSupervisor, fn _ -> original end) end)

    :sys.replace_state(ArcanaWeb.TaskSupervisor, fn state ->
      %{state | max_children: 0}
    end)

    :ok
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
