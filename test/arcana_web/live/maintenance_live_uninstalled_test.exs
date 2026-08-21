defmodule ArcanaWeb.MaintenanceLiveUninstalledTest do
  @moduledoc """
  The Maintenance page's graph actions on a database without the graph schema.

  The page itself mounts fine because its orphan counts rescue, and the buttons
  are hidden at zero counts - but hiding a control does not stop an event pushed
  over the socket, and each of these handlers reaches arcana_graph_entities. A
  forged `delete_orphans` took the whole LiveView down with 42P01.

  Same approach as the Graph page tests: rename the table inside the sandbox
  transaction so the rollback restores it, `async: false` so the LiveView shares
  this test's connection.
  """
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL

  setup do
    SQL.query!(
      Repo,
      "ALTER TABLE arcana_graph_entities RENAME TO arcana_graph_entities_hidden",
      []
    )

    :ok
  end

  test "the page still mounts", %{conn: conn} do
    refute Arcana.Graph.installed?(Repo), "precondition: the graph table must look absent"

    assert {:ok, _view, _html} = live(conn, "/arcana/maintenance")
  end

  test "a forged graph action says so instead of crashing", %{conn: conn} do
    for event <- ~w(delete_orphans assign_orphans rebuild_graph detect_communities
                    summarize_communities) do
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      html = render_hook(view, event, %{})

      assert html =~ "GraphRAG is not installed",
             "#{event} should report the missing schema"

      assert Process.alive?(view.pid), "#{event} should not take the LiveView down"
    end
  end

  test "events that have nothing to do with the graph still work", %{conn: conn} do
    # The guard names its events rather than swallowing everything, so the rest
    # of the page has to keep behaving normally.
    {:ok, view, _html} = live(conn, "/arcana/maintenance")

    html = render_hook(view, "select_reembed_collection", %{"collection" => "anything"})

    refute html =~ "GraphRAG is not installed",
           "a non-graph event must not hit the graph guard"

    assert Process.alive?(view.pid)
  end
end
