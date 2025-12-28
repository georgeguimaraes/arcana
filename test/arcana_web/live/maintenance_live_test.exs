defmodule ArcanaWeb.MaintenanceLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Maintenance page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Maintenance"
    end

    test "shows navigation with maintenance tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/maintenance']")
    end

    test "shows embedding configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Embedding Configuration"
      assert html =~ "Type"
    end

    test "shows re-embed section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Re-embed All Chunks"
    end

    test "has re-embed button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      assert has_element?(view, "button[phx-click='reembed']")
    end
  end
end
