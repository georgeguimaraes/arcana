defmodule ArcanaWeb.CollectionsLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Graph.{Community, Entity, EntityMention}

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

    test "deleting a collection that still has documents explains itself", %{conn: conn} do
      # documents.collection_id is ON DELETE RESTRICT, so this delete raises
      # in the database. Unrescued that takes the whole page down.
      {:ok, _doc} = Arcana.ingest("Content", repo: Repo, collection: "still-full")
      collection = Repo.get_by(Arcana.Collection, name: "still-full")

      {:ok, view, _html} = live(conn, "/arcana/collections")

      view |> element("#delete-collection-#{collection.id}") |> render_click()
      html = view |> element("#confirm-delete") |> render_click()

      assert html =~ "still has documents"
      assert has_element?(view, "#collection-still-full")
      assert Repo.get(Arcana.Collection, collection.id)
    end

    test "shows document and chunk counts", %{conn: conn} do
      {:ok, _doc} = Arcana.ingest("Content", repo: Repo, collection: "with-docs")

      {:ok, view, _html} = live(conn, "/arcana/collections")

      # Check the collection row has proper counts in the table
      assert has_element?(view, "#collection-with-docs")
      # Table headers should show Docs and Chunks columns
      assert has_element?(view, "th", "Docs")
      assert has_element?(view, "th", "Chunks")
    end

    test "does not count communities backed only by unpublished entities", %{conn: conn} do
      {:ok, published} = Arcana.ingest("Published", repo: Repo, collection: "published-graph")
      {:ok, hidden_collection} = Arcana.Collection.get_or_create("hidden-graph", Repo)

      {:ok, hidden_document} =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Failed",
          collection_id: hidden_collection.id,
          status: :failed
        })
        |> Repo.insert()

      published_chunk = Repo.get_by!(Arcana.Chunk, document_id: published.id)

      hidden_chunk =
        %Arcana.Chunk{}
        |> Arcana.Chunk.changeset(%{
          text: "Hidden",
          document_id: hidden_document.id,
          embedding: List.duplicate(0.0, 384)
        })
        |> Repo.insert!()

      published_entity = insert_entity("Published entity", published.collection_id)
      hidden_entity = insert_entity("Hidden entity", hidden_collection.id)
      insert_mention(published_entity.id, published_chunk.id)
      insert_mention(hidden_entity.id, hidden_chunk.id)
      insert_community(published.collection_id, published_entity.id)
      insert_community(hidden_collection.id, hidden_entity.id)

      {:ok, view, _html} = live(conn, "/arcana/collections")

      assert has_element?(view, "#collection-published-graph td:nth-child(7)", "1")
      assert has_element?(view, "#collection-hidden-graph td:nth-child(7)", "0")
    end
  end

  defp insert_entity(name, collection_id) do
    %Entity{}
    |> Entity.changeset(%{
      name: name,
      type: "concept",
      collection_id: collection_id
    })
    |> Repo.insert!()
  end

  defp insert_mention(entity_id, chunk_id) do
    %EntityMention{}
    |> EntityMention.changeset(%{entity_id: entity_id, chunk_id: chunk_id})
    |> Repo.insert!()
  end

  defp insert_community(collection_id, entity_id) do
    %Community{}
    |> Community.changeset(%{
      collection_id: collection_id,
      entity_ids: [entity_id],
      level: 0
    })
    |> Repo.insert!()
  end
end
