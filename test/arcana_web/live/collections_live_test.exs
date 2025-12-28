defmodule ArcanaWeb.CollectionsLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Collections page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/collections")

      assert html =~ "Collections"
    end

    test "shows navigation with collections tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/collections")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/collections']")
    end

    test "lists existing collections", %{conn: conn} do
      {:ok, _} = Arcana.Collection.get_or_create("live-collection", Repo, "Test desc")

      {:ok, view, _html} = live(conn, "/arcana/collections")

      assert has_element?(view, "#collection-live-collection")
      assert render(view) =~ "live-collection"
      assert render(view) =~ "Test desc"
    end

    test "creates a new collection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/collections")

      view
      |> form("#new-collection-form", %{
        "collection" => %{
          "name" => "brand-new",
          "description" => "Brand new collection"
        }
      })
      |> render_submit()

      assert has_element?(view, "#collection-brand-new")
      assert render(view) =~ "Brand new collection"

      # Verify in DB
      collection = Repo.get_by(Arcana.Collection, name: "brand-new")
      assert collection
      assert collection.description == "Brand new collection"
    end

    test "edits a collection", %{conn: conn} do
      {:ok, collection} = Arcana.Collection.get_or_create("edit-target", Repo, "Original")

      {:ok, view, _html} = live(conn, "/arcana/collections")

      view |> element("#edit-collection-#{collection.id}") |> render_click()

      view
      |> form("#edit-collection-form-#{collection.id}", %{
        "collection" => %{"description" => "Updated desc"}
      })
      |> render_submit()

      assert render(view) =~ "Updated desc"

      updated = Repo.get!(Arcana.Collection, collection.id)
      assert updated.description == "Updated desc"
    end

    test "deletes a collection", %{conn: conn} do
      {:ok, collection} = Arcana.Collection.get_or_create("to-delete", Repo, nil)

      {:ok, view, _html} = live(conn, "/arcana/collections")

      view |> element("#delete-collection-#{collection.id}") |> render_click()
      view |> element("#confirm-delete") |> render_click()

      refute has_element?(view, "#collection-to-delete")
      assert Repo.get(Arcana.Collection, collection.id) == nil
    end

    test "shows document count", %{conn: conn} do
      {:ok, _doc} = Arcana.ingest("Content", repo: Repo, collection: "with-docs")

      {:ok, _view, html} = live(conn, "/arcana/collections")

      assert html =~ "1 document"
    end
  end
end
