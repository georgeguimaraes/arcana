defmodule ArcanaWeb.DashboardLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Collections tab" do
    test "displays collections tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana")

      assert has_element?(view, "[data-tab='collections']")
    end

    test "lists existing collections", %{conn: conn} do
      # Create a collection
      {:ok, _} = Arcana.Collection.get_or_create("my-collection", Repo, "Test description")

      {:ok, view, _html} = live(conn, "/arcana")

      # Click on collections tab
      view |> element("[data-tab='collections']") |> render_click()

      assert has_element?(view, "#collection-my-collection")
      assert render(view) =~ "my-collection"
      assert render(view) =~ "Test description"
    end

    test "creates a new collection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana")

      # Click on collections tab
      view |> element("[data-tab='collections']") |> render_click()

      # Fill in the create form
      view
      |> form("#new-collection-form", %{
        "collection" => %{
          "name" => "new-collection",
          "description" => "A new collection"
        }
      })
      |> render_submit()

      # Verify the collection was created
      assert has_element?(view, "#collection-new-collection")
      assert render(view) =~ "new-collection"
      assert render(view) =~ "A new collection"

      # Verify it's in the database
      collection = Repo.get_by(Arcana.Collection, name: "new-collection")
      assert collection
      assert collection.description == "A new collection"
    end

    test "edits an existing collection", %{conn: conn} do
      # Create a collection
      {:ok, collection} = Arcana.Collection.get_or_create("edit-me", Repo, "Original description")

      {:ok, view, _html} = live(conn, "/arcana")

      # Click on collections tab
      view |> element("[data-tab='collections']") |> render_click()

      # Click edit button
      view |> element("#edit-collection-#{collection.id}") |> render_click()

      # Update the form
      view
      |> form("#edit-collection-form-#{collection.id}", %{
        "collection" => %{
          "description" => "Updated description"
        }
      })
      |> render_submit()

      # Verify the update
      assert render(view) =~ "Updated description"

      # Verify in database
      updated = Repo.get!(Arcana.Collection, collection.id)
      assert updated.description == "Updated description"
    end

    test "deletes a collection", %{conn: conn} do
      # Create a collection
      {:ok, collection} = Arcana.Collection.get_or_create("delete-me", Repo, nil)

      {:ok, view, _html} = live(conn, "/arcana")

      # Click on collections tab
      view |> element("[data-tab='collections']") |> render_click()

      # Click delete button
      view |> element("#delete-collection-#{collection.id}") |> render_click()

      # Confirm deletion
      view |> element("#confirm-delete") |> render_click()

      # Verify collection is removed from view
      refute has_element?(view, "#collection-#{collection.id}")

      # Verify deleted from database
      assert Repo.get(Arcana.Collection, collection.id) == nil
    end

    test "shows collection document count", %{conn: conn} do
      # Create a collection with documents
      {:ok, _doc} =
        Arcana.ingest("Test content",
          repo: Repo,
          collection: "counted-collection"
        )

      {:ok, view, _html} = live(conn, "/arcana")

      # Click on collections tab
      view |> element("[data-tab='collections']") |> render_click()

      # Verify document count is shown
      assert render(view) =~ "1 document"
    end
  end

  # TODO: Implement document editing and filtering in future iteration
  # describe "Documents tab" do
  #   @tag :skip
  #   test "edits document metadata", %{conn: conn} do
  #     ...
  #   end
  #
  #   @tag :skip
  #   test "filters documents by collection", %{conn: conn} do
  #     ...
  #   end
  # end
end
