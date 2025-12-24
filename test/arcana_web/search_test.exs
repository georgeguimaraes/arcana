defmodule ArcanaWeb.SearchTest do
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "search tab" do
    setup %{conn: conn} do
      # Ingest some documents for searching
      {:ok, doc1} = Arcana.ingest("Elixir is a functional programming language", repo: Repo)
      {:ok, doc2} = Arcana.ingest("Python is great for machine learning", repo: Repo)

      {:ok, doc3} =
        Arcana.ingest("JavaScript runs in the browser", repo: Repo, source_id: "js-docs")

      %{conn: conn, doc1: doc1, doc2: doc2, doc3: doc3}
    end

    test "renders search form with query input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Switch to search tab
      html = view |> element("[data-tab='search']") |> render_click()

      assert html =~ "Search"
      assert has_element?(view, "#search-form")

      assert has_element?(view, "input[name='query']") or
               has_element?(view, "textarea[name='query']")
    end

    test "shows limit control", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = view |> element("[data-tab='search']") |> render_click()

      assert has_element?(view, "[name='limit']") or html =~ "Limit"
    end

    test "shows threshold control", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = view |> element("[data-tab='search']") |> render_click()

      assert has_element?(view, "[name='threshold']") or html =~ "Threshold"
    end

    test "performs search and shows results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element("[data-tab='search']") |> render_click()

      html =
        view
        |> form("#search-form", %{query: "functional programming"})
        |> render_submit()

      # Should show results with the Elixir document
      assert html =~ "Elixir"
      assert html =~ "functional"
    end

    test "shows similarity scores", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element("[data-tab='search']") |> render_click()

      html =
        view
        |> form("#search-form", %{query: "programming language"})
        |> render_submit()

      # Should show a score (number between 0 and 1)
      assert html =~ ~r/0\.\d+/ or html =~ "score"
    end

    test "can filter by source_id", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      view |> element("[data-tab='search']") |> render_click()

      html =
        view
        |> form("#search-form", %{query: "programming", source_id: "js-docs"})
        |> render_submit()

      # Should only show JavaScript document
      assert html =~ "JavaScript"
      refute html =~ "Elixir"
      refute html =~ "Python"
    end
  end
end
