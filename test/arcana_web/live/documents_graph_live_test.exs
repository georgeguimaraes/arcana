defmodule ArcanaWeb.DocumentsGraphLiveTest do
  @moduledoc """
  Tests for graph indexing features in DocumentsLive.

  These tests modify global Application config (:arcana, :graph) so they
  must run with async: false to avoid races with other tests.
  """
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "graph indexing" do
    setup do
      # Start TaskSupervisor for async operations
      start_supervised!({Task.Supervisor, name: Arcana.TaskSupervisor})

      # Enable graph for these tests
      original = Application.get_env(:arcana, :graph, [])
      Application.put_env(:arcana, :graph, Keyword.put(original, :enabled, true))

      on_exit(fn ->
        Application.put_env(:arcana, :graph, original)
      end)

      :ok
    end

    test "shows Build Graph button when viewing document detail", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Content for graph", repo: Repo, collection: "test-graph")

      {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

      assert has_element?(view, "button[phx-click='build_graph']")
    end

    test "hides Build Graph button when graph is disabled", %{conn: conn} do
      Application.put_env(:arcana, :graph, enabled: false)

      {:ok, doc} = Arcana.ingest("Content no graph", repo: Repo, collection: "test-no-graph")

      {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

      refute has_element?(view, "button[phx-click='build_graph']")
    end

    test "shows loading state when Build Graph is clicked", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Content to index", repo: Repo, collection: "graph-build")

      {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

      # Before clicking, button says "Build Graph"
      assert render(view) =~ "Build Graph"

      # Use render_click's return value to capture the immediate state after click
      # (before async task completes and sends :graph_complete message)
      html = view |> element("button[phx-click='build_graph']") |> render_click()

      # After clicking, button shows loading state
      assert html =~ "Building..."
    end

    test "resets loading state after graph build completes", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Content to index", repo: Repo, collection: "graph-build-2")

      {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

      # Click to start loading - use render_click's return value to verify loading state
      html = view |> element("button[phx-click='build_graph']") |> render_click()
      assert html =~ "Building..."

      # Send completion message
      send(view.pid, {:graph_complete, {:ok, %{entity_count: 5, relationship_count: 3}}})

      # After completion, button should be back to normal (not disabled)
      html = render(view)
      refute html =~ "Building..."
      assert html =~ "Build Graph"
    end
  end
end
