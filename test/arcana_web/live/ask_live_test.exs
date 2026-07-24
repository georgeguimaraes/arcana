defmodule ArcanaWeb.AskLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Collection
  alias Arcana.Graph.{Entity, Relationship}

  describe "agentic result rendering with nested chunks" do
    test "handles agentic results with nested %{chunks: [...]} structure", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      # Simulate what format_agentic_result produces after flattening
      # This verifies the template can render the normalized format
      result = %{
        question: "What is Elixir?",
        answer: "Elixir is a dynamic, functional language.",
        results: [
          %{
            id: 1,
            text: "Elixir is a language",
            score: 0.95,
            document_id: "doc1",
            chunk_index: 0
          },
          %{id: 2, text: "Built on Erlang VM", score: 0.90, document_id: "doc1", chunk_index: 1}
        ],
        expanded_query: "Elixir programming language functional",
        sub_questions: ["What is Elixir?", "How does Elixir work?"],
        selected_collections: ["docs"]
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      # Verify chunks render correctly
      assert html =~ "0.95"
      assert html =~ "0.9"
      assert html =~ "Elixir is a language"
      assert html =~ "Built on Erlang VM"
      assert html =~ "doc1"
      assert html =~ "Chunk 0"
      assert html =~ "Chunk 1"
    end
  end

  describe "Ask page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/ask")

      assert html =~ "Ask"
    end

    test "shows navigation with ask tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/ask']")
    end

    test "shows three sub-tabs: Advanced, Pipeline, Loop", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, ".arcana-ask-sub-tab", "Advanced")
      assert has_element?(view, ".arcana-ask-sub-tab", "Pipeline")
      assert has_element?(view, ".arcana-ask-sub-tab", "Loop")
    end

    test "default sub-tab is Advanced", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Advanced")
    end

    test "shows question textarea (shared across all sub-tabs)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, "#ask-form")
      assert has_element?(view, "textarea[name='question']")
    end

    test "Advanced sub-tab does not show the Pipeline step boxes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      refute has_element?(view, ".arcana-pipeline")
    end

    test "clicking Pipeline sub-tab shows the ordered step boxes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Pipeline") |> render_click()

      assert has_element?(view, ".arcana-pipeline")
      assert has_element?(view, ".arcana-ask-sub-tab.active", "Pipeline")
    end

    test "Pipeline sub-tab shows the new Gate, Query Rewriting, and Multi-hop Reasoning steps",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Pipeline") |> render_click()

      html = render(view)
      assert html =~ "Gate"
      assert html =~ "Query Rewriting"
      assert html =~ "Multi-hop Reasoning"
    end

    test "Pipeline sub-tab has the Query Expansion, Decomposition, Reranking, Grounding boxes",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Pipeline") |> render_click()

      html = render(view)
      assert html =~ "Query Expansion"
      assert html =~ "Decomposition"
      assert html =~ "Reranking"
      assert html =~ "Grounding"
    end

    test "clicking Loop sub-tab shows the loop settings section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Loop") |> render_click()

      assert has_element?(view, ".arcana-loop-settings")
      assert has_element?(view, ".arcana-ask-sub-tab.active", "Loop")
    end

    test "Loop sub-tab shows max_iterations and controller_llm settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Loop") |> render_click()

      html = render(view)
      assert html =~ "Controller"
      assert html =~ "Max iterations"
    end

    test "Loop sub-tab shows form inputs for max_iterations, chunk_cap and grounding",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Loop") |> render_click()

      assert has_element?(view, "input[name='max_iterations']")
      assert has_element?(view, "input[name='chunk_cap']")
      assert has_element?(view, "input[name='use_ground_loop']")
    end

    test "Loop sub-tab submit is enabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Loop") |> render_click()

      # Submit should be enabled once Loop execution is wired up.
      refute has_element?(view, ".arcana-ask-actions button[type='submit'][disabled]")
    end
  end

  describe "Loop result rendering" do
    test "renders the agent trace when result_type is :loop", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        result_type: :loop,
        question: "What is a TARDIS?",
        answer: "A TARDIS is the Doctor's time machine.",
        tool_history: [
          %{
            tool: :search,
            args: %{query: "TARDIS"},
            iteration: 0,
            summary: "Found 5 chunks. Top 5: [abc]...",
            returned_chunk_ids: ["abc", "def"]
          },
          %{
            tool: :search,
            args: %{query: "TARDIS bigger on the inside"},
            iteration: 1,
            summary: "Found 3 chunks.",
            returned_chunk_ids: ["ghi"]
          },
          %{
            tool: :answer,
            args: %{text: "A TARDIS is the Doctor's time machine."},
            iteration: 2,
            summary: "Answered.",
            returned_chunk_ids: []
          }
        ],
        terminated_by: :answered,
        iterations: 3,
        chunks: [
          %{id: "abc", text: "text one", score: 0.9},
          %{id: "def", text: "text two", score: 0.8},
          %{id: "ghi", text: "text three", score: 0.85}
        ],
        grounding: nil
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      # Agent trace section visible
      assert html =~ "Agent trace"
      # Each iteration's tool and query shown
      assert html =~ "search"
      assert html =~ "TARDIS"
      assert html =~ "TARDIS bigger on the inside"
      assert html =~ "answer"
      # Termination reason shown
      assert html =~ "answered"
      # Iteration + chunk counts shown
      assert html =~ "3"
      # Answer still displayed
      assert html =~ "A TARDIS is the Doctor&#39;s time machine."
    end

    test "renders terminated_by :max_iterations with fallback synthesis note", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      result = %{
        result_type: :loop,
        question: "q",
        answer: "synthesized fallback answer",
        tool_history:
          Enum.map(0..9, fn i ->
            %{
              tool: :search,
              args: %{query: "q#{i}"},
              iteration: i,
              summary: "...",
              returned_chunk_ids: ["c#{i}"]
            }
          end),
        terminated_by: :max_iterations,
        iterations: 10,
        chunks: [],
        grounding: nil
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "max_iterations"
      assert html =~ "synthesized fallback answer"
    end

    test "does not render Agent trace when result_type is not :loop", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      # A Pipeline/Advanced result should not show the Agent trace section.
      result = %{
        question: "q",
        answer: "a",
        results: [],
        expanded_query: nil,
        sub_questions: nil,
        selected_collections: nil
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      refute html =~ "Agent trace"
    end
  end

  describe "Ask sub-tab URL routing" do
    test "landing on /arcana/ask lands on Advanced sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Advanced")
    end

    test "landing on /arcana/ask/advanced lands on Advanced sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask/advanced")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Advanced")
    end

    test "landing on /arcana/ask/pipeline lands on Pipeline sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask/pipeline")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Pipeline")
      # Pipeline step boxes should be visible
      assert has_element?(view, ".arcana-pipeline")
    end

    test "landing on /arcana/ask/loop lands on Loop sub-tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask/loop")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Loop")
      assert has_element?(view, ".arcana-loop-settings")
    end

    test "unknown sub-tab path falls back to Advanced", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask/nonsense")

      assert has_element?(view, ".arcana-ask-sub-tab.active", "Advanced")
    end

    test "clicking a sub-tab updates the URL via push_patch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Pipeline") |> render_click()

      # The URL should have been patched to include the sub_tab segment.
      assert_patched(view, "/arcana/ask/pipeline")
    end

    test "loop spinner uses 'Running agent loop...' label while a Loop run is in flight", %{
      conn: conn
    } do
      # Defends ask_loading_label/2 :loop branch. Loop doesn't emit pipeline
      # telemetry, so the old `@pipeline_step || "Running pipeline..."`
      # branch wrongly showed "Running pipeline..." during a Loop run.
      put_arcana_env(:llm, "zai:test-stub")

      # Stub a slow runner so the spinner is visible when we render.
      put_arcana_env(:loop_runner, fn _ctx, _opts ->
        Process.sleep(200)

        {:ok,
         %Arcana.Loop.Context{
           question: "q",
           answer: "ok",
           tool_history: [],
           iterations: 1,
           terminated_by: :answered,
           chunks: [],
           grounding: nil
         }}
      end)

      {:ok, view, _html} = live(conn, "/arcana/ask/loop")

      view
      |> form("#ask-form", %{"question" => "q"})
      |> render_submit()

      # Render immediately after submit while the stubbed runner is still
      # asleep — the LiveView should be in the ask_running state with the
      # loop-specific label.
      html = render(view)
      assert html =~ "Running agent loop..."
      refute html =~ "Running pipeline..."
    end

    test "all/none toggle on Pipeline tab updates checkbox state via server", %{conn: conn} do
      # Defends set_pipeline_steps + the checked={@pipeline_steps[...]}
      # bindings. Pre-fix this used inline onclick JS that mutated DOM
      # without telling the LiveView, so the server never knew which
      # boxes were checked.
      {:ok, view, _html} = live(conn, "/arcana/ask/pipeline")

      # Initially every step is unchecked.
      refute has_element?(view, "input[name='use_gate'][checked]")
      refute has_element?(view, "input[name='use_ground'][checked]")

      # Global "all" (the top-level button, not a group-scoped one) should
      # check every step. Targets the button without a phx-value-group.
      view
      |> element(
        "button.arcana-pipeline-toggle-link[phx-value-mode='all']:not([phx-value-group])"
      )
      |> render_click()

      assert has_element?(view, "input[name='use_gate'][checked]")
      assert has_element?(view, "input[name='use_rewrite'][checked]")
      assert has_element?(view, "input[name='self_correct'][checked]")
      assert has_element?(view, "input[name='use_ground'][checked]")

      # Global "none" should clear every step.
      view
      |> element(
        "button.arcana-pipeline-toggle-link[phx-value-mode='none']:not([phx-value-group])"
      )
      |> render_click()

      refute has_element?(view, "input[name='use_gate'][checked]")
      refute has_element?(view, "input[name='use_ground'][checked]")
    end

    test "per-group all/none toggle only affects the target phase", %{conn: conn} do
      # Defends the phx-value-group scoping on set_pipeline_steps.
      # Clicking "all" in the Query preparation group should flip the
      # gate/rewrite/expand/decompose boxes and leave retrieval/answer
      # boxes alone.
      {:ok, view, _html} = live(conn, "/arcana/ask/pipeline")

      view
      |> element("button.arcana-pipeline-toggle-link[phx-value-group='query']", "all")
      |> render_click()

      # Query phase steps: checked.
      assert has_element?(view, "input[name='use_gate'][checked]")
      assert has_element?(view, "input[name='use_rewrite'][checked]")
      assert has_element?(view, "input[name='use_expand'][checked]")
      assert has_element?(view, "input[name='use_decompose'][checked]")

      # Retrieval + Answer phase steps: still unchecked.
      refute has_element?(view, "input[name='use_reason'][checked]")
      refute has_element?(view, "input[name='use_rerank'][checked]")
      refute has_element?(view, "input[name='self_correct'][checked]")
      refute has_element?(view, "input[name='use_ground'][checked]")

      # Now flip the Answer phase on: self_correct and use_ground check,
      # query-phase stays on (leaves other groups untouched).
      view
      |> element("button.arcana-pipeline-toggle-link[phx-value-group='answer']", "all")
      |> render_click()

      assert has_element?(view, "input[name='self_correct'][checked]")
      assert has_element?(view, "input[name='use_ground'][checked]")
      assert has_element?(view, "input[name='use_gate'][checked]")
      refute has_element?(view, "input[name='use_reason'][checked]")
    end

    test "switching sub-tabs clears stale ask result and error", %{conn: conn} do
      # Defends maybe_reset_ask_state. Stub a Loop run that returns a
      # canned answer, click Loop, submit, then switch back to Advanced
      # and assert the rendered result section is gone — without the
      # reset, the previous Loop result would still render under the
      # Advanced form and confuse the user.
      put_arcana_env(:llm, "zai:test-stub")

      put_arcana_env(:loop_runner, fn _ctx, _opts ->
        {:ok,
         %Arcana.Loop.Context{
           question: "stub",
           answer: "should-be-cleared-on-switch",
           tool_history: [],
           iterations: 1,
           terminated_by: :answered,
           chunks: [],
           grounding: nil
         }}
      end)

      {:ok, view, _html} = live(conn, "/arcana/ask/loop")

      view
      |> form("#ask-form", %{"question" => "q"})
      |> render_submit()

      :timer.sleep(50)
      assert render(view) =~ "should-be-cleared-on-switch"

      view |> element(".arcana-ask-sub-tab", "Advanced") |> render_click()

      refute render(view) =~ "should-be-cleared-on-switch"
    end
  end

  describe "Loop execution handler" do
    test "submitting the Loop form with an injected controller runs Loop.run/2", %{conn: conn} do
      # The handle_event for submit checks that :arcana, :llm is configured
      # before running anything. Set a placeholder so the handler proceeds;
      # the stubbed loop_runner ignores the opts so the value doesn't matter.
      put_arcana_env(:llm, "zai:test-stub")

      # Stub the loop_runner so we don't need a real LLM. The stub returns a
      # canned Loop.Context shaped result. This is the smallest seam we can
      # introduce to make the handler testable without spinning up a real
      # controller.
      put_arcana_env(:loop_runner, fn _ctx, _opts ->
        {:ok,
         %Arcana.Loop.Context{
           question: "stubbed",
           answer: "stubbed answer from test",
           tool_history: [
             %{
               tool: :search,
               args: %{query: "q"},
               iteration: 0,
               summary: "...",
               returned_chunk_ids: []
             },
             %{
               tool: :answer,
               args: %{text: "stubbed answer from test"},
               iteration: 1,
               summary: "Answered.",
               returned_chunk_ids: []
             }
           ],
           iterations: 2,
           terminated_by: :answered,
           chunks: [],
           grounding: nil
         }}
      end)

      {:ok, view, _html} = live(conn, "/arcana/ask")

      view |> element(".arcana-ask-sub-tab", "Loop") |> render_click()

      # Submit the form via render_submit
      view
      |> form("#ask-form", %{
        "question" => "test question",
        "max_iterations" => "5",
        "chunk_cap" => "20"
      })
      |> render_submit()

      # The ask_complete message should produce a loop-shaped result.
      # Wait for the async task to complete.
      :timer.sleep(50)
      html = render(view)

      assert html =~ "Agent trace"
      assert html =~ "stubbed answer from test"
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

    test "shows Graph-Assisted toggle after selecting a graph-enabled collection", %{
      conn: conn,
      collection: collection
    } do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      # Not visible before selecting a collection
      refute has_element?(view, "input[name='graph_search']")

      # Select the graph-enabled collection
      view
      |> form("#ask-form", %{"collections" => [collection.name]})
      |> render_change()

      assert has_element?(view, "input[name='graph_search']")
    end

    test "toggle label shows Graph-Assisted with hint text", %{conn: conn, collection: collection} do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      view
      |> form("#ask-form", %{"collections" => [collection.name]})
      |> render_change()

      html = render(view)
      assert html =~ "Graph-Assisted"
      assert html =~ "Find results through entity relationships"
    end

    test "toggle appears in both Advanced and Pipeline sub-tabs when graph collection selected",
         %{
           conn: conn,
           collection: collection
         } do
      {:ok, view, _html} = live(conn, "/arcana/ask")

      # Select graph collection
      view
      |> form("#ask-form", %{"collections" => [collection.name]})
      |> render_change()

      # Advanced (default): inline toggle below textarea
      assert has_element?(view, ".arcana-deep-search-toggle input[name='graph_search']")

      # Switch to Pipeline: toggle appears as a radio fork inside the Search step box
      view |> element(".arcana-ask-sub-tab", "Pipeline") |> render_click()

      assert has_element?(view, ".arcana-pipeline-fork input[name='graph_search']")
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

      refute has_element?(view, "input[name='graph_search']")
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
