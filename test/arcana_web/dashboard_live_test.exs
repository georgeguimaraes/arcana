defmodule ArcanaWeb.DashboardLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "dashboard" do
    test "renders with Documents and Search tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Documents"
      assert html =~ "Search"
    end

    test "Documents tab is active by default", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      # Documents tab should be active/selected
      assert html =~ ~r/Documents.*active/s or has_element?(view, "[data-tab='documents'].active")
    end

    test "can switch to Search tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = view |> element("[data-tab='search']") |> render_click()

      assert html =~ "Search"
    end

    test "search tab has mode selector with semantic, fulltext, and hybrid options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Switch to search tab
      view |> element("[data-tab='search']") |> render_click()

      # Should have a mode select
      assert has_element?(view, "select[name='mode']")

      # Should have all three options
      assert has_element?(view, "select[name='mode'] option[value='semantic']")
      assert has_element?(view, "select[name='mode'] option[value='fulltext']")
      assert has_element?(view, "select[name='mode'] option[value='hybrid']")
    end
  end
end
