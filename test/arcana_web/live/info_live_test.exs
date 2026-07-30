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

    test "shows Grounder section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Grounder"
    end

    test "shows Loop section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "Loop"
    end

    test "Loop section reflects configured loop options", %{conn: conn} do
      put_arcana_env(:loop,
        max_iterations: 7,
        chunk_cap: 25,
        controller_llm: "zai:test"
      )

      {:ok, _view, html} = live(conn, "/arcana/info")

      assert html =~ "7"
      assert html =~ "25"
    end

    test "Loop section shows defaults when no :loop config is set", %{conn: conn} do
      put_arcana_env(:loop, [])

      {:ok, _view, html} = live(conn, "/arcana/info")

      # Defaults: max_iterations 10, chunk_cap 30
      assert html =~ "Loop"
      assert html =~ "10"
      assert html =~ "30"
    end
  end
end
