defmodule ArcanaWeb.DocumentsLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Documents page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/documents")

      assert html =~ "Documents"
    end

    test "shows stats bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/documents")

      assert has_element?(view, ".arcana-stats")
    end

    test "shows navigation with documents tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/documents")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/documents']")
    end

    test "lists documents", %{conn: conn} do
      {:ok, _doc} = Arcana.ingest("Test content for documents", repo: Repo)

      {:ok, _view, html} = live(conn, "/arcana/documents")

      assert html =~ "Test content for documents"
    end

    test "filters documents by collection", %{conn: conn} do
      {:ok, _doc1} = Arcana.ingest("Doc in filter-a", repo: Repo, collection: "filter-a")
      {:ok, _doc2} = Arcana.ingest("Doc in filter-b", repo: Repo, collection: "filter-b")

      {:ok, view, _html} = live(conn, "/arcana/documents")

      # Both visible initially
      html = render(view)
      assert html =~ "Doc in filter-a"
      assert html =~ "Doc in filter-b"

      # Filter by filter-a
      view |> element("#filter-collection-filter-a") |> render_click()

      html = render(view)
      assert html =~ "Doc in filter-a"
      refute html =~ "Doc in filter-b"
    end

    test "views document detail", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Detailed content here", repo: Repo)

      {:ok, view, _html} = live(conn, "/arcana/documents")

      view |> element("[data-view-doc='#{doc.id}']") |> render_click()

      html = render(view)
      assert html =~ "Detailed content here"
      assert html =~ "Chunk"
    end

    test "ingests text content", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/documents")

      view
      |> form("#ingest-form", %{"content" => "New ingested content"})
      |> render_submit()

      html = render(view)
      assert html =~ "New ingested content"
    end

    test "deletes document", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Content to delete", repo: Repo)

      {:ok, view, _html} = live(conn, "/arcana/documents")

      assert render(view) =~ "Content to delete"

      view |> element("[data-delete-doc='#{doc.id}']") |> render_click()

      refute render(view) =~ "Content to delete"
    end
  end
end
