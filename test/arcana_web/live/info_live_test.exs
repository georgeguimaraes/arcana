defmodule ArcanaWeb.InfoLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Info page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Configuration"
    end

    test "shows navigation with info tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/info")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/info']")
    end

    test "shows repository configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Repository"
    end

    test "shows embedding configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Embedding"
    end

    test "shows LLM configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "LLM"
    end

    test "shows reranker configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Reranker"
    end

    test "shows raw configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Raw Configuration"
      assert html =~ "config :arcana"
    end
  end
end
