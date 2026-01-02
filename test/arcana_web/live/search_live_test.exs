defmodule ArcanaWeb.SearchLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Search page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/search")

      assert html =~ "Search"
    end

    test "shows navigation with search tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/search")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/search']")
    end

    test "shows search form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/search")

      assert has_element?(view, "#search-form")
      assert has_element?(view, "input[name='query']")
    end

    test "performs search and shows results", %{conn: conn} do
      {:ok, _doc} = Arcana.ingest("Searchable content about Elixir", repo: Repo)

      {:ok, view, _html} = live(conn, "/arcana/search")

      # Use fulltext mode since mock embeddings don't provide semantic similarity
      view
      |> form("#search-form", %{"query" => "Elixir", "mode" => "fulltext"})
      |> render_submit()

      html = render(view)
      assert html =~ "Searchable content about Elixir"
    end

    test "shows no results message for empty search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/search")

      view
      |> form("#search-form", %{"query" => "nonexistent12345"})
      |> render_submit()

      html = render(view)
      assert html =~ "No results found"
    end

    test "shows search options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/search")

      assert has_element?(view, "select[name='mode']")
      assert has_element?(view, "select[name='limit']")
      assert has_element?(view, "input[name='threshold']")
    end
  end
end
