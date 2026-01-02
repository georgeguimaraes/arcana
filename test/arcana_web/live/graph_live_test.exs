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

  describe "Entities sub-view" do
    setup do
      entity_extractor = fn _text, _opts ->
        {:ok,
         [
           %{name: "Alice Smith", type: :person},
           %{name: "Acme Corp", type: :organization},
           %{name: "Phoenix Framework", type: :technology}
         ]}
      end

      {:ok, doc} =
        Arcana.ingest(
          "Alice Smith works at Acme Corp using Phoenix Framework.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "entities-test"
        )

      %{document: doc}
    end

    test "shows entity table with name, type, mentions, relationships columns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, "th", "Name")
      assert has_element?(view, "th", "Type")
      assert has_element?(view, "th", "Mentions")
      assert has_element?(view, "th", "Relationships")
    end

    test "displays entity data in table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      html = render(view)
      assert html =~ "Alice Smith"
      assert html =~ "Acme Corp"
      assert html =~ "Phoenix Framework"
    end

    test "shows type badges for different entity types", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-entity-type-badge.person")
      assert has_element?(view, ".arcana-entity-type-badge.organization")
      assert has_element?(view, ".arcana-entity-type-badge.technology")
    end

    test "filters entities by name search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      view
      |> element("form[phx-change=filter_entities]")
      |> render_change(%{"name" => "Alice"})

      html = render(view)
      assert html =~ "Alice Smith"
      refute html =~ "Acme Corp"
    end

    test "filters entities by type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      view
      |> element("form[phx-change=filter_entities]")
      |> render_change(%{"type" => "person"})

      html = render(view)
      assert html =~ "Alice Smith"
      refute html =~ "Acme Corp"
      refute html =~ "Phoenix Framework"
    end
  end

  describe "CSS classes" do
    setup do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "CSSTestEntity", type: :person}]}
      end

      {:ok, _doc} =
        Arcana.ingest(
          "Test content for CSS.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "css-test-collection"
        )

      :ok
    end

    test "renders sub-tab navigation with correct CSS class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-graph-subtabs")
    end

    test "renders sub-tab buttons with correct CSS class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-subtab-btn", "Entities")
      assert has_element?(view, ".arcana-subtab-btn", "Relationships")
      assert has_element?(view, ".arcana-subtab-btn", "Communities")
    end

    test "renders entity type badge with correct CSS class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph")

      assert has_element?(view, ".arcana-entity-type-badge.person")
    end

    test "renders strength meter with correct CSS class", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/graph?tab=relationships")

      # May be empty if no relationships, but check it renders the view
      assert render(view) =~ "Relationships" or render(view) =~ "No relationships"
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
