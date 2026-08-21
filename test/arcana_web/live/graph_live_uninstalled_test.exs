defmodule ArcanaWeb.GraphLiveUninstalledTest do
  @moduledoc """
  The Graph page on a database that never ran the graph migration.

  The graph tables carry their own migration version, so installing arcana
  without them is supported - and the dashboard used to mount the page anyway
  and raise `relation "arcana_graph_entities" does not exist`, from a nav link
  reachable on every page.

  `async: false` so the sandbox runs in shared mode and the LiveView uses this
  test's connection. That is what makes the setup safe: renaming the table is
  DDL inside the test's transaction, so the rollback at the end puts it back.
  Nothing here leaks to another test or survives the run.
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

  test "says so instead of raising", %{conn: conn} do
    refute Arcana.Graph.installed?(Repo), "precondition: the graph table must look absent"

    {:ok, _view, html} = live(conn, "/arcana/graph")

    assert html =~ "GraphRAG is not installed in this database"
    assert html =~ "Arcana.Graph.Migration.up"
  end

  test "does not render the entity browser it cannot fill", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/arcana/graph")

    refute has_element?(view, "select[name='collection']"),
           "the collection selector queries entities, so it must not render"
  end

  test "a forged event does not crash the page the controls are hidden from", %{conn: conn} do
    # Hiding the controls only stops the honest client. Every graph handler
    # reaches a loader that queries arcana_graph_entities, so an event pushed
    # straight over the socket would still crash the LiveView.
    {:ok, view, _html} = live(conn, "/arcana/graph")

    for {event, params} <- [
          {"switch_subtab", %{"tab" => "relationships"}},
          {"filter_entities", %{"name" => "anything"}},
          {"select_entity", %{"id" => Ecto.UUID.generate()}},
          {"filter_communities", %{"name" => "x"}}
        ] do
      assert render_hook(view, event, params) =~ "GraphRAG is not installed",
             "#{event} should be ignored, not crash the view"
    end

    assert Process.alive?(view.pid), "the LiveView should have survived every forged event"
  end

  test "the rest of the dashboard still works without the graph schema", %{conn: conn} do
    # The point of the split migration: skipping graph costs you the graph page
    # and nothing else.
    # Every page reachable from the nav, not a subset. The first version of this
    # list omitted /arcana/ask, which was the one that still raised 42P01 - so
    # the test asserted the claim it was meant to check and passed anyway.
    for path <- [
          "/arcana",
          "/arcana/documents",
          "/arcana/collections",
          "/arcana/search",
          "/arcana/ask",
          "/arcana/evaluation",
          "/arcana/maintenance",
          "/arcana/info"
        ] do
      assert {:ok, _view, _html} = live(conn, path), "#{path} should mount without graph tables"
    end
  end
end
