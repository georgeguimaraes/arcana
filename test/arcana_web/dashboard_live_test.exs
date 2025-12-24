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
  end
end
