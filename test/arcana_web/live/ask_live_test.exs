defmodule ArcanaWeb.AskLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Collection
  alias Arcana.Graph.{Entity, Relationship}

  describe "Ask page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/ask")

      assert html =~ "Ask"
    end

    test "shows navigation with ask tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/ask']")
    end

    test "shows mode selector with Simple and Agentic", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "button", "Simple")
      assert has_element?(view, "button", "Agentic")
    end

    test "shows question textarea", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "#ask-form")
      assert has_element?(view, "textarea[name='question']")
    end
  end

  describe "Graph-Enhanced toggle" do
    setup do
      # Create a collection with graph data
      {:ok, collection} =
        %Collection{}
        |> Collection.changeset(%{name: "graph-collection"})
        |> Repo.insert()

      # Create an entity to make graph data "enabled"
      {:ok, entity} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection.id
        })
        |> Repo.insert()

      # Create a collection without graph data
      {:ok, empty_collection} =
        %Collection{}
        |> Collection.changeset(%{name: "empty-collection"})
        |> Repo.insert()

      {:ok, collection: collection, entity: entity, empty_collection: empty_collection}
    end

    test "shows Graph-Enhanced toggle when at least one collection has graph data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "input[name='graph_enhanced']")
      assert has_element?(view, ".arcana-graph-toggle")
    end

    test "toggle label shows Graph-Enhanced with hint text", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/ask")

      assert html =~ "Graph-Enhanced"
      assert html =~ "Uses entity/relationship context"
    end

    test "toggle is visible in both Simple and Agentic modes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      # Simple mode (default)
      assert has_element?(view, "input[name='graph_enhanced']")

      # Switch to Agentic
      view |> element("button", "Agentic") |> render_click()

      assert has_element?(view, "input[name='graph_enhanced']")
    end
  end

  describe "Graph-Enhanced toggle visibility" do
    test "toggle is hidden when no collections have graph data", %{conn: conn} do
      # Create collection without any entities
      {:ok, _collection} =
        %Collection{}
        |> Collection.changeset(%{name: "no-graph-collection"})
        |> Repo.insert()

      {:ok, view, _html} = live(conn, "/arcana/ask")

      refute has_element?(view, "input[name='graph_enhanced']")
      refute has_element?(view, ".arcana-graph-toggle")
    end
  end

  describe "Graph Context in results" do
    setup do
      # Create a collection with full graph data
      {:ok, collection} =
        %Collection{}
        |> Collection.changeset(%{name: "tech-companies"})
        |> Repo.insert()

      {:ok, openai} =
        %Entity{}
        |> Entity.changeset(%{
          name: "OpenAI",
          type: "organization",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, sam} =
        %Entity{}
        |> Entity.changeset(%{
          name: "Sam Altman",
          type: "person",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, gpt4} =
        %Entity{}
        |> Entity.changeset(%{
          name: "GPT-4",
          type: "technology",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, _leads_rel} =
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: sam.id,
          target_id: openai.id,
          type: "LEADS",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, _created_rel} =
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: openai.id,
          target_id: gpt4.id,
          type: "CREATED",
          collection_id: collection.id
        })
        |> Repo.insert()

      {:ok, collection: collection, entities: [openai, sam, gpt4]}
    end

    test "shows Graph Context section when graph_enhanced is true in results", %{conn: conn} do
      # This test verifies that when a search returns with graph_enhanced: true,
      # the UI shows a Graph Context section

      {:ok, view, _html} = live(conn, "/arcana/ask")

      # Mock result by sending ask_complete with graph context
      result = %{
        question: "Who leads OpenAI?",
        answer: "Sam Altman leads OpenAI",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [
          %{name: "OpenAI", type: "organization"},
          %{name: "Sam Altman", type: "person"}
        ],
        matched_relationships: [
          %{source: "Sam Altman", target: "OpenAI", type: "LEADS"}
        ]
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "Graph Context"
      assert html =~ "Matched Entities"
    end

    test "displays matched entities with name and type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [
          %{name: "OpenAI", type: "organization"},
          %{name: "Sam Altman", type: "person"}
        ],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "OpenAI"
      assert html =~ "organization"
      assert html =~ "Sam Altman"
      assert html =~ "person"
    end

    test "displays key relationships", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [],
        matched_relationships: [
          %{source: "Sam Altman", target: "OpenAI", type: "LEADS"},
          %{source: "OpenAI", target: "GPT-4", type: "CREATED"}
        ]
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "Key Relationships"
      assert html =~ "Sam Altman"
      assert html =~ "LEADS"
      assert html =~ "OpenAI"
    end

    test "shows View in Graph link for entities", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [%{id: "abc123", name: "OpenAI", type: "organization"}],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})

      assert has_element?(view, "a", "View in Graph")
    end

    test "shows fallback message when no entities matched", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "No entity matches"
      assert html =~ "used vector search only"
    end

    test "Graph Context section is collapsible", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [%{name: "OpenAI", type: "organization"}],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})

      # Should have a collapsible element
      assert has_element?(view, ".arcana-graph-context")

      assert has_element?(view, "button[phx-click='toggle_graph_context']") or
               has_element?(view, "[phx-click='toggle_graph_context']")
    end
  end

  describe "Chunk attribution" do
    test "shows 'via: entity names' for chunks from graph search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [
          %{
            text: "OpenAI develops GPT-4",
            score: 0.95,
            document_id: "doc1",
            chunk_index: 0,
            graph_sources: ["OpenAI", "GPT-4"]
          }
        ],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [%{name: "OpenAI", type: "organization"}],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "via:"
      assert html =~ "OpenAI"
    end

    test "does not show 'via:' for pure vector chunks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        question: "Test",
        answer: "Test answer",
        results: [
          %{
            text: "Some unrelated content",
            score: 0.85,
            document_id: "doc2",
            chunk_index: 0
            # No graph_sources
          }
        ],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil,
        graph_enhanced: true,
        matched_entities: [],
        matched_relationships: []
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      refute html =~ "via:"
    end
  end
end
