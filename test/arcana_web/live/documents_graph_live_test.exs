defmodule ArcanaWeb.DocumentsGraphLiveTest do
  @moduledoc """
  Tests for graph indexing features in DocumentsLive.
  """
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "graph indexing" do
    setup do
      # Arcana.TaskSupervisor is started globally in test/test_helper.exs.

      # Enable graph for these tests, composing on the global base so the
      # fake entity_extractor from config/test.exs survives.
      base = Application.get_env(:arcana, :graph, [])
      put_arcana_env(:graph, Keyword.put(base, :enabled, true))

      :ok
    end

    test "shows Build Graph button when viewing document detail", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Content for graph", repo: Repo, collection: "test-graph")

      {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

      assert has_element?(view, "button[phx-click='build_graph']")
    end

    test "hides Build Graph button when graph is disabled", %{conn: conn} do
      put_arcana_env(:graph, enabled: false)

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
