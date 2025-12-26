defmodule ArcanaWeb.DocumentsTest do
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "documents tab" do
    test "lists existing documents", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Test document content", repo: Repo)

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Test document content"
      assert html =~ doc.id
    end

    test "shows empty state when no documents", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "No documents" or html =~ "no documents"
    end

    test "can ingest new document via form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        view
        |> form("#ingest-form", %{content: "New document to ingest"})
        |> render_submit()

      assert html =~ "New document to ingest"
    end

    test "can delete a document", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Document to delete", repo: Repo)

      {:ok, view, html} = live(conn, "/")
      assert html =~ "Document to delete"

      html =
        view
        |> element("[data-delete-doc='#{doc.id}']")
        |> render_click()

      refute html =~ "Document to delete"
    end

    test "shows document metadata", %{conn: conn} do
      {:ok, doc} =
        Arcana.ingest("Content with metadata",
          repo: Repo,
          source_id: "my-source",
          metadata: %{"author" => "Jane"}
        )

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "my-source"
      assert html =~ doc.id
      # Metadata column should display key-value pairs
      assert html =~ "author: Jane"
    end

    test "ingest form has format selector with plaintext, markdown, and elixir options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Should have a format select in the ingest form
      assert has_element?(view, "#ingest-form select[name='format']")

      # Should have format options
      assert has_element?(view, "#ingest-form select[name='format'] option[value='plaintext']")
      assert has_element?(view, "#ingest-form select[name='format'] option[value='markdown']")
      assert has_element?(view, "#ingest-form select[name='format'] option[value='elixir']")
    end

    test "document list has pagination controls", %{conn: conn} do
      # Create 15 documents to trigger pagination (assuming 10 per page)
      for i <- 1..15 do
        {:ok, _doc} = Arcana.ingest("Document number #{i}", repo: Repo)
      end

      {:ok, view, html} = live(conn, "/")

      # Should show pagination controls
      assert html =~ "arcana-pagination"
      assert has_element?(view, "[data-page]")
    end

    test "can view document details with full content and chunks", %{conn: conn} do
      content = "This is a longer document with more content for testing the detail view."
      {:ok, doc} = Arcana.ingest(content, repo: Repo, metadata: %{"title" => "Test Doc"})

      {:ok, view, _html} = live(conn, "/")

      # Click view button for the document
      html = view |> element("[data-view-doc='#{doc.id}']") |> render_click()

      # Should show document detail view
      assert html =~ "arcana-doc-detail"
      assert html =~ content
      assert html =~ "Chunks"
    end
  end
end
