defmodule ArcanaWeb.AllowedCollectionsTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Collection

  # These tests exercise the /scoped dashboard from the test router, whose
  # :collections MFA reads the allowed list from the conn's session. Each
  # test seeds its own restriction via init_test_session, so the suite
  # stays async-safe.

  defp restrict(conn, allowed) do
    Plug.Test.init_test_session(conn, allowed_collections: allowed)
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
