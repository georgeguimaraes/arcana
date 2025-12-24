defmodule ArcanaWeb.StylesTest do
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "dashboard styling" do
    test "includes scoped styles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Should have a style tag with arcana styles
      assert html =~ "<style>"
      assert html =~ ".arcana-dashboard"
    end

    test "uses purple theme colors", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Should include purple color values
      assert html =~ "#7c3aed" or html =~ "#8b5cf6" or html =~ "#6d28d9"
    end

    test "tabs have active state styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Documents tab should be active by default
      assert has_element?(view, ".arcana-tab.active")
    end
  end
end
