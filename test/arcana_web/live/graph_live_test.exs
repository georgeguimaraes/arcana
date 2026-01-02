defmodule ArcanaWeb.GraphLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Graph page without graph data" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/graph")

      assert html =~ "Graph"
    end

    test "shows navigation with graph tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/graph']")
    end

    test "graph tab appears after collections in navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/graph")

      # Graph should come after Collections and before Search
      assert html =~ ~r/Collections.*Graph.*Search/s
    end

    test "shows collection selector", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-collection-selector")
    end

    test "shows empty state when no graph data exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/graph")

      assert html =~ "No Graph Data"
      assert html =~ "graph: true"
    end

    test "hides sub-tabs when no graph data exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      refute has_element?(view, ".arcana-graph-subtabs")
    end

    test "shows collections with graph-enabled indicators", %{conn: conn} do
      # Create a collection (without graph data)
      {:ok, _} = Arcana.Collection.get_or_create("no-graph-collection", Repo, "Test")

      {:ok, view, _html} = live(conn, "/arcana/graph")

      # Should show collection with disabled indicator
      assert render(view) =~ "no-graph-collection"
    end
  end

  describe "Graph page with graph data" do
    setup do
      # Create test data with graph entities
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "TestEntity", type: :concept}]}
      end

      {:ok, doc} =
        Arcana.ingest(
          "Test content with TestEntity mentioned.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "graph-test-collection"
        )

      %{document: doc}
    end

    test "shows collection as graph-enabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      html = render(view)
      assert html =~ "graph-test-collection"
      # Should show enabled indicator
      assert has_element?(view, ".arcana-graph-enabled") or html =~ "✓"
    end

    test "shows entities in Entities sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      html = render(view)
      assert html =~ "TestEntity"
    end

    test "shows three sub-tabs: Entities, Relationships, Communities", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-graph-subtabs")
      assert has_element?(view, "button", "Entities")
      assert has_element?(view, "button", "Relationships")
      assert has_element?(view, "button", "Communities")
    end

    test "defaults to Entities sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, "button.active", "Entities")
    end

    test "switches to Relationships sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      view |> element("button", "Relationships") |> render_click()

      assert has_element?(view, "button.active", "Relationships")
    end

    test "switches to Communities sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      view |> element("button", "Communities") |> render_click()

      assert has_element?(view, "button.active", "Communities")
    end
  end

  describe "URL state preservation" do
    setup do
      # Create test data with graph entities
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "URLTestEntity", type: :concept}]}
      end

      {:ok, doc} =
        Arcana.ingest(
          "Test content for URL state.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "url-test-collection"
        )

      %{document: doc}
    end

    test "preserves tab in URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph?tab=relationships")

      assert has_element?(view, "button.active", "Relationships")
    end

    test "preserves collection in URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph?collection=url-test-collection")

      # Collection should be selected
      html = render(view)
      assert html =~ "url-test-collection"
    end
  end
end
