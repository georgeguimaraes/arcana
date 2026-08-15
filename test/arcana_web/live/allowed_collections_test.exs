defmodule ArcanaWeb.AllowedCollectionsTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Collection
  alias Arcana.Graph.{Community, Entity, Relationship}

  # These tests exercise the /scoped dashboard from the test router, whose
  # :collections MFA reads the allowed list from the conn's session. Each
  # test seeds its own restriction via init_test_session, so the suite
  # stays async-safe.

  defp restrict(conn, allowed) do
    Plug.Test.init_test_session(conn, allowed_collections: allowed)
  end

  defp seed_entity(collection, entity_name) do
    {:ok, _} =
      Arcana.ingest("#{entity_name} shows up in #{collection}",
        repo: Repo,
        graph: true,
        entity_extractor: fn _text, _opts -> {:ok, [%{name: entity_name, type: "concept"}]} end,
        collection: collection
      )
  end

  # The ask flow answers asynchronously, so poll the render instead of
  # sleeping a magic number of milliseconds.
  defp render_until(view, expected, attempts \\ 50) do
    html = render(view)

    cond do
      html =~ expected ->
        html

      attempts <= 0 ->
        html

      true ->
        Process.sleep(20)
        render_until(view, expected, attempts - 1)
    end
  end

  describe "collections page" do
    test "lists only allowed collections", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      assert html =~ "tenant-a"
      refute html =~ "other"
    end

    test "rejects creating a collection outside the allowed set", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      view
      |> form("#new-collection-form", %{"collection" => %{"name" => "evil"}})
      |> render_submit()

      refute Repo.get_by(Collection, name: "evil")
    end

    test "allows creating a collection inside the allowed set", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      view
      |> form("#new-collection-form", %{"collection" => %{"name" => "tenant-a"}})
      |> render_submit()

      assert Repo.get_by(Collection, name: "tenant-a")
    end

    test "rejects deleting a collection outside the allowed set by forged id", %{conn: conn} do
      {:ok, other} = Collection.get_or_create("other", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      render_click(view, "delete_collection", %{"id" => other.id})

      assert Repo.get(Collection, other.id)
    end

    test "graph stat columns stay hidden when only disallowed collections have graph data",
         %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      seed_entity("other", "SecretEntity")

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      refute html =~ "<th>Entities</th>"
    end

    test "rejects renaming a collection under a restriction", %{conn: conn} do
      {:ok, collection} = Collection.get_or_create("tenant-a", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      render_submit(view, "update_collection", %{
        "id" => collection.id,
        "collection" => %{"name" => "landgrab", "description" => "mine now"}
      })

      assert Repo.get(Collection, collection.id).name == "tenant-a"
    end

    test "still allows editing a description under a restriction", %{conn: conn} do
      {:ok, collection} = Collection.get_or_create("tenant-a", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      render_submit(view, "update_collection", %{
        "id" => collection.id,
        "collection" => %{"description" => "tenant notes"}
      })

      assert Repo.get(Collection, collection.id).description == "tenant notes"
    end

    test "an empty allowed set hides the create form", %{conn: conn} do
      {:ok, view, html} = conn |> restrict([]) |> live("/scoped/collections")

      refute has_element?(view, "#new-collection-form")
      assert html =~ "No collections are available"
      refute html =~ "Create one above"
    end
  end

  describe "documents page" do
    test "lists only documents from allowed collections", %{conn: conn} do
      {:ok, _} = Arcana.ingest("Allowed tenant content", repo: Repo, collection: "tenant-a")
      {:ok, _} = Arcana.ingest("Hidden tenant content", repo: Repo, collection: "other")

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      assert html =~ "Allowed tenant content"
      refute html =~ "Hidden tenant content"
      # filter bar and ingest select only offer allowed collections
      refute html =~ "filter-collection-other"
      refute html =~ ~s(<option value="">default</option>)
    end

    test "rejects a forged ingest event naming a disallowed collection", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      render_submit(view, "ingest", %{
        "content" => "smuggled",
        "format" => "plaintext",
        "collection" => "other"
      })

      assert {:ok, []} = Arcana.list_documents(repo: Repo)
    end

    test "rejects ingest into the default collection when it is not allowed", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      render_submit(view, "ingest", %{"content" => "smuggled", "format" => "plaintext"})

      assert {:ok, []} = Arcana.list_documents(repo: Repo)
    end

    test "rejects deleting a document outside the allowed collections", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Hidden tenant content", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      render_click(view, "delete", %{"id" => doc.id})

      assert {:ok, _doc} = Arcana.get_document(doc.id, repo: Repo)
    end

    test "does not show documents from other collections via forged view event", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Hidden tenant content", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      html = render_click(view, "view_document", %{"id" => doc.id})

      refute html =~ "Hidden tenant content"
    end

    # The delete carries the allowed-collection predicate in the DELETE
    # itself, so a collection renamed out of scope after the page rendered
    # can't be deleted through a stale allow-check.
    test "a collection renamed out of scope blocks the delete", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Allowed tenant content", repo: Repo, collection: "tenant-a")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      collection = Repo.get_by!(Collection, name: "tenant-a")
      Repo.update!(Collection.changeset(collection, %{name: "renamed-away"}))

      render_click(view, "delete", %{"id" => doc.id})

      assert {:ok, _doc} = Arcana.get_document(doc.id, repo: Repo)
    end

    test "still deletes a document inside the allowed collections", %{conn: conn} do
      {:ok, doc} = Arcana.ingest("Allowed tenant content", repo: Repo, collection: "tenant-a")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      render_click(view, "delete", %{"id" => doc.id})

      assert {:error, :not_found} = Arcana.get_document(doc.id, repo: Repo)
    end

    test "a malformed document id is rejected instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      render_click(view, "delete", %{"id" => "not-a-uuid"})

      assert render(view) =~ "Documents"
    end
  end

  describe "search page" do
    test "only offers and searches allowed collections", %{conn: conn} do
      {:ok, _} = Arcana.ingest("Elixir content for tenant a", repo: Repo, collection: "tenant-a")
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      refute html =~ ~s(value="other")

      # no selection means "all allowed collections", never everything
      html = render_submit(view, "search", %{"query" => "Elixir"})

      assert html =~ "Elixir content for tenant a"
      refute html =~ "Elixir content for others"
    end

    test "refuses a search naming a disallowed collection", %{conn: conn} do
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      html =
        render_submit(view, "search", %{"query" => "Elixir", "collections" => ["other"]})

      refute html =~ "Elixir content for others"
    end

    test "an empty allowed set never searches anything", %{conn: conn} do
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict([]) |> live("/scoped/search")

      html = render_submit(view, "search", %{"query" => "Elixir"})

      refute html =~ "Elixir content for others"
    end

    # An allowed name with no collection row (never created, or deleted
    # between the mount and the submit) has to fail the search, not widen
    # it to every collection.
    test "a restricted search does not widen when the allowed collection is missing",
         %{conn: conn} do
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["ghost"]) |> live("/scoped/search")

      html = render_submit(view, "search", %{"query" => "Elixir"})

      refute html =~ "Elixir content for others"
    end

    test "a restricted search does not widen when the allowed collection is deleted mid-session",
         %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      Repo.delete!(Repo.get_by!(Collection, name: "tenant-a"))

      html = render_submit(view, "search", %{"query" => "Elixir"})

      refute html =~ "Elixir content for others"
    end
  end

  describe "ask page" do
    test "rejects a forged ask naming a disallowed collection before any retrieval",
         %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      html =
        render_submit(view, "ask_submit", %{
          "question" => "What is hidden?",
          "sub_tab" => "advanced",
          "collections" => ["other"]
        })

      assert html =~ "not allowed"
    end

    test "an empty allowed set refuses every ask", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict([]) |> live("/scoped/ask")

      html =
        render_submit(view, "ask_submit", %{
          "question" => "anything",
          "sub_tab" => "advanced"
        })

      assert html =~ "not allowed"
    end

    test "rejects a forged non-list collections selection", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      html =
        render_submit(view, "ask_submit", %{
          "question" => "What is hidden?",
          "sub_tab" => "advanced",
          "collections" => "other"
        })

      assert html =~ "not allowed"
    end

    # Under :strict_collections the search fails before the LLM is ever
    # called, so this needs no real model behind the placeholder.
    test "a restricted advanced ask fails closed when the allowed collection is missing",
         %{conn: conn} do
      put_arcana_env(:llm, "zai:test-stub")
      {:ok, _} = Arcana.ingest("Elixir content for others", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["ghost"]) |> live("/scoped/ask")

      render_submit(view, "ask_submit", %{
        "question" => "What is hidden?",
        "sub_tab" => "advanced"
      })

      html = render_until(view, "unknown_collection")

      assert html =~ "unknown_collection"
      refute html =~ "Elixir content for others"
    end

    test "rejects a forged map collections selection", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      html =
        render_submit(view, "ask_submit", %{
          "question" => "What is hidden?",
          "sub_tab" => "advanced",
          "collections" => %{"0" => "other"}
        })

      assert html =~ "not allowed"
    end

    test "only renders allowed collection checkboxes", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      assert html =~ "tenant-a"
      refute html =~ ~s(value="other")
    end
  end

  describe "graph page" do
    test "restricted dashboards get no All Collections option", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/graph")

      refute html =~ "All Collections"
      refute html =~ ~s(value="other")
    end

    test "header stats count only allowed collections", %{conn: conn} do
      {:ok, _} = Arcana.ingest("one", repo: Repo, collection: "tenant-a")
      {:ok, _} = Arcana.ingest("two", repo: Repo, collection: "other")
      {:ok, _} = Arcana.ingest("three", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/graph")

      assert has_element?(view, ".arcana-stat-value", "1")
      refute has_element?(view, ".arcana-stat-value", "3")
    end

    # "ghost" is allowed but has no collection row, so it resolves to no
    # collection id. It sorts first in the allowed list, so the selection
    # normalization picks it and every loader has to refuse rather than
    # fall through to an unscoped read. tenant-a supplies the graph data
    # that keeps the entity table (and its forgeable events) rendered.
    test "a forged filter event cannot read entities outside the allowed set", %{conn: conn} do
      seed_entity("tenant-a", "AllowedEntity")
      seed_entity("other", "SecretEntity")

      {:ok, view, html} = conn |> restrict(["ghost", "tenant-a"]) |> live("/scoped/graph")

      refute html =~ "SecretEntity"

      html = render_change(view, "filter_entities", %{"name" => ""})

      refute html =~ "SecretEntity"
    end

    test "still browses entities when the selection resolves to an allowed collection",
         %{conn: conn} do
      seed_entity("tenant-a", "AllowedEntity")
      seed_entity("other", "SecretEntity")

      {:ok, view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/graph")

      assert html =~ "AllowedEntity"
      refute html =~ "SecretEntity"

      html = render_change(view, "filter_entities", %{"name" => "Allowed"})

      assert html =~ "AllowedEntity"
      refute html =~ "SecretEntity"
    end

    test "a forged pagination event cannot read entities outside the allowed set", %{conn: conn} do
      seed_entity("tenant-a", "AllowedEntity")
      seed_entity("other", "SecretEntity")

      {:ok, view, _html} = conn |> restrict(["ghost", "tenant-a"]) |> live("/scoped/graph")

      html = render_click(view, "entities_page", %{"page" => "1"})

      refute html =~ "SecretEntity"
    end

    test "a forged relationship filter event cannot escape the allowed set", %{conn: conn} do
      seed_entity("tenant-a", "AllowedEntity")
      seed_entity("other", "SecretSource")
      seed_entity("other", "SecretTarget")

      other = Repo.get_by!(Collection, name: "other")
      source = Repo.get_by!(Entity, name: "SecretSource", collection_id: other.id)
      target = Repo.get_by!(Entity, name: "SecretTarget", collection_id: other.id)

      Repo.insert!(%Relationship{
        source_id: source.id,
        target_id: target.id,
        type: "knows",
        strength: 8
      })

      {:ok, view, _html} =
        conn |> restrict(["ghost", "tenant-a"]) |> live("/scoped/graph?tab=relationships")

      html = render_change(view, "filter_relationships", %{"search" => ""})

      refute html =~ "SecretSource"
    end

    test "a forged community filter event cannot escape the allowed set", %{conn: conn} do
      seed_entity("tenant-a", "AllowedEntity")
      seed_entity("other", "SecretEntity")

      other = Repo.get_by!(Collection, name: "other")

      Repo.insert!(%Community{
        collection_id: other.id,
        level: 0,
        summary: "SecretCommunity summary",
        entity_ids: []
      })

      {:ok, view, _html} =
        conn |> restrict(["ghost", "tenant-a"]) |> live("/scoped/graph?tab=communities")

      html = render_change(view, "filter_communities", %{"search" => ""})

      refute html =~ "SecretCommunity"
    end
  end

  describe "maintenance page" do
    test "restricted dashboards cannot run collection-wide actions", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)

      {:ok, view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      refute html =~ "All Collections"

      # no collection selected: the action is refused instead of running
      # globally, so the progress UI never appears
      html = render_click(view, "reembed", %{})
      refute html =~ "Re-embedding..."
    end

    test "a forged selection outside the allowed set does not stick", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      render_change(view, "select_reembed_collection", %{"collection" => "other"})

      html = render_click(view, "reembed", %{})
      refute html =~ "Re-embedding..."
    end
  end

  describe "header stats" do
    test "counts only allowed collections", %{conn: conn} do
      {:ok, _} = Arcana.ingest("one", repo: Repo, collection: "tenant-a")
      {:ok, _} = Arcana.ingest("two", repo: Repo, collection: "other")
      {:ok, _} = Arcana.ingest("three", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/documents")

      assert has_element?(view, ".arcana-stat-value", "1")
      refute has_element?(view, ".arcana-stat-value", "3")
    end
  end

  describe "unrestricted scoped mount (:all)" do
    test "behaves like a normal dashboard when the MFA returns :all", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      # no session key set: the MFA falls back to :all
      {:ok, _view, html} = live(conn, "/scoped/collections")

      assert html =~ "tenant-a"
      assert html =~ "other"
    end
  end
end
