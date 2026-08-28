defmodule ArcanaWeb.AllowedCollectionsTest do
  use ArcanaWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Arcana.{Collection, Document}
  alias Arcana.Evaluation
  alias Arcana.Graph.Community
  alias Arcana.Graph.{Community, Entity, Relationship, RelationshipEvidence}

  # These tests exercise the /scoped dashboard from the test router, whose
  # :collections MFA reads the allowed list from the conn's session. Each
  # test seeds its own restriction via init_test_session, so the suite
  # stays async-safe.

  defp insert_dirty_community(collection_name) do
    {:ok, collection} = Collection.get_or_create(collection_name, Repo)

    %Community{}
    |> Community.changeset(%{
      level: 0,
      collection_id: collection.id,
      entity_ids: [],
      summary: nil,
      dirty: true
    })
    |> Repo.insert!()
  end

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

  # Evaluation test cases reach a collection through their chunks, so the
  # seed ingests a document and links every chunk it produced. The tokens
  # callers pass in must survive HTML escaping untouched (no apostrophes),
  # otherwise a `refute html =~ token` passes for the wrong reason.
  defp seed_test_case(collection, text, question, reference_answer \\ nil) do
    {:ok, doc} = Arcana.ingest(text, repo: Repo, collection: collection)

    chunks = Repo.all(from(c in Arcana.Chunk, where: c.document_id == ^doc.id))

    {:ok, test_case} =
      Evaluation.create_test_case(
        repo: Repo,
        question: question,
        relevant_chunk_ids: Enum.map(chunks, & &1.id),
        reference_answer: reference_answer
      )

    {test_case, chunks}
  end

  defp insert_run(config) do
    {:ok, run} =
      %Evaluation.Run{}
      |> Evaluation.Run.changeset(%{status: :completed, config: config, test_case_count: 4242})
      |> Repo.insert()

    run
  end

  defp run_ids do
    Repo.all(from(r in Evaluation.Run, select: r.id))
  end

  # A "newest row" lookup would happily return a run this test never made:
  # `inserted_at` has second granularity, so its `id` tiebreak is a random
  # UUID, and the shared test database can still hold committed leftovers
  # from a crashed run. Diffing against the ids seen before the submit
  # pins the assertion to the run the test actually created.
  defp run_created_since(ids_before) do
    Repo.one!(from(r in Evaluation.Run, where: r.id not in ^ids_before))
  end

  # The ask flow answers asynchronously, so poll the render instead of
  # sleeping a magic number of milliseconds.

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

    test "a malformed collection id is rejected instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/collections")

      render_click(view, "delete_collection", %{"id" => "not-a-uuid"})

      render_submit(view, "update_collection", %{
        "id" => "not-a-uuid",
        "collection" => %{"description" => "nope"}
      })

      assert render(view) =~ "Collections"
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

    test "lists and filters across several allowed collections", %{conn: conn} do
      {:ok, _} = Arcana.ingest("First allowed document", repo: Repo, collection: "tenant-a")
      {:ok, _} = Arcana.ingest("Second allowed document", repo: Repo, collection: "tenant-b")
      {:ok, _} = Arcana.ingest("Outside document", repo: Repo, collection: "other")

      {:ok, view, html} =
        conn |> restrict(["tenant-a", "tenant-b"]) |> live("/scoped/documents")

      assert html =~ "First allowed document"
      assert html =~ "Second allowed document"
      refute html =~ "Outside document"

      html = render_click(view, "filter_by_collection", %{"collection" => "tenant-b"})

      refute html =~ "First allowed document"
      assert html =~ "Second allowed document"
      refute html =~ "Outside document"
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

    test "ignores a malformed document id in the URL", %{conn: conn} do
      assert {:ok, _view, html} =
               conn |> restrict(["tenant-a"]) |> live("/scoped/documents?doc=not-a-uuid")

      refute html =~ "Document Details"
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
      render_click(view, "view_document", %{"id" => "not-a-uuid"})
      render_click(view, "build_graph", %{})

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

    test "rejects the whole search when a selection mixes allowed and disallowed collections",
         %{conn: conn} do
      {:ok, _} = Arcana.ingest("Visible mixed-scope content", repo: Repo, collection: "tenant-a")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      html =
        render_submit(view, "search", %{
          "query" => "mixed-scope",
          "collections" => ["tenant-a", "other"]
        })

      refute html =~ "Visible mixed-scope content"
    end

    test "a malformed document id is rejected instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      render_click(view, "view_search_document", %{"id" => "not-a-uuid"})

      assert render(view) =~ "Search"
    end

    test "a forged detail id cannot open a document outside the allowed scope", %{conn: conn} do
      {:ok, doc} =
        Arcana.ingest("Hidden search detail", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      html = render_click(view, "view_search_document", %{"id" => doc.id})

      refute html =~ "Hidden search detail"
    end

    test "a forged detail id cannot open an unpublished document", %{conn: conn} do
      {:ok, collection} = Collection.get_or_create("tenant-a", Repo)

      pending =
        %Document{}
        |> Document.changeset(%{
          content: "Pending search detail",
          status: :pending,
          collection_id: collection.id
        })
        |> Repo.insert!()

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/search")

      html = render_click(view, "view_search_document", %{"id" => pending.id})

      refute html =~ "Pending search detail"
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

    test "rejects the whole ask when a selection mixes allowed and disallowed collections",
         %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      html =
        render_submit(view, "ask_submit", %{
          "question" => "What is hidden?",
          "sub_tab" => "advanced",
          "collections" => ["tenant-a", "other"]
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

    test "title hydration uses the completed documents in the run's effective scope", %{
      conn: conn
    } do
      {:ok, allowed} =
        Arcana.ingest("Allowed title content",
          repo: Repo,
          collection: "tenant-a",
          metadata: %{"title" => "Allowed title"}
        )

      {:ok, hidden} =
        Arcana.ingest("Hidden title content",
          repo: Repo,
          collection: "other",
          metadata: %{"title" => "Hidden title"}
        )

      {:ok, collection} = Collection.get_or_create("tenant-a", Repo)

      pending =
        %Document{}
        |> Document.changeset(%{
          content: "Pending title content",
          status: :pending,
          collection_id: collection.id,
          metadata: %{"title" => "Pending title"}
        })
        |> Repo.insert!()

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/ask")

      result = %{
        question: "Which titles?",
        answer: "Three chunks",
        results: [
          %{id: "one", text: "one", score: 0.9, document_id: allowed.id, chunk_index: 0},
          %{id: "two", text: "two", score: 0.8, document_id: hidden.id, chunk_index: 0},
          %{id: "three", text: "three", score: 0.7, document_id: pending.id, chunk_index: 0}
        ],
        collection_scope: :all,
        selected_collections: nil
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "Allowed title"
      refute html =~ "Hidden title"
      refute html =~ "Pending title"
    end

    test "title hydration preserves a multi-collection run scope", %{conn: conn} do
      documents =
        for {collection, title} <- [
              {"tenant-a", "Tenant A title"},
              {"tenant-b", "Tenant B title"},
              {"tenant-c", "Tenant C title"}
            ] do
          {:ok, document} =
            Arcana.ingest("Content for #{collection}",
              repo: Repo,
              collection: collection,
              metadata: %{"title" => title}
            )

          document
        end

      {:ok, view, _html} =
        conn
        |> restrict(["tenant-a", "tenant-b", "tenant-c"])
        |> live("/scoped/ask")

      result = %{
        question: "Which titles?",
        answer: "Three chunks",
        results:
          Enum.map(documents, fn document ->
            %{
              id: document.id,
              text: "chunk",
              score: 0.9,
              document_id: document.id,
              chunk_index: 0
            }
          end),
        collection_scope: ["tenant-a", "tenant-b"],
        selected_collections: ["tenant-a", "tenant-b"]
      }

      send(view.pid, {:ask_complete, {:ok, result}})
      html = render(view)

      assert html =~ "Tenant A title"
      assert html =~ "Tenant B title"
      refute html =~ "Tenant C title"
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

    test "malformed selection ids are rejected instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/graph")

      render_click(view, "select_entity", %{"id" => "not-a-uuid"})
      render_click(view, "select_relationship", %{"id" => "not-a-uuid"})
      render_click(view, "select_community", %{"id" => "not-a-uuid"})

      assert render(view) =~ "Graph"
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

      relationship =
        %Relationship{}
        |> Relationship.changeset(%{
          source_id: source.id,
          target_id: target.id,
          type: "knows",
          strength: 8
        })
        |> Repo.insert!()

      chunk =
        Repo.one!(
          from(c in Arcana.Chunk,
            join: d in Arcana.Document,
            on: c.document_id == d.id,
            where: d.collection_id == ^other.id,
            limit: 1
          )
        )

      %RelationshipEvidence{}
      |> RelationshipEvidence.changeset(%{
        relationship_id: relationship.id,
        chunk_id: chunk.id
      })
      |> Repo.insert!()

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

  describe "evaluation page" do
    test "lists only test cases whose chunks live in allowed collections", %{conn: conn} do
      seed_test_case("other", "SecretEvalChunkZulu", "SecretEvalQuestionZulu")
      seed_test_case("tenant-a", "AllowedEvalChunkZulu", "AllowedEvalQuestionZulu")

      {:ok, _view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      assert html =~ "AllowedEvalQuestionZulu"
      refute html =~ "SecretEvalQuestionZulu"
      assert html =~ "Test Cases (1)"
    end

    test "hides a test case that straddles an allowed and a disallowed collection",
         %{conn: conn} do
      {_tc, [allowed_chunk]} = seed_test_case("tenant-a", "AllowedEvalChunkZulu", "allowed")
      {_tc, [secret_chunk]} = seed_test_case("other", "SecretEvalChunkZulu", "secret")

      {:ok, straddler} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "StraddlingEvalQuestionZulu",
          relevant_chunk_ids: [allowed_chunk.id, secret_chunk.id]
        )

      {:ok, view, html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      refute html =~ "StraddlingEvalQuestionZulu"

      html = render_click(view, "toggle_test_case", %{"id" => straddler.id})

      refute html =~ "SecretEvalChunkZulu"
    end

    test "a forged toggle cannot expand a test case outside the allowed collections",
         %{conn: conn} do
      {secret, _chunks} =
        seed_test_case(
          "other",
          "SecretEvalChunkZulu",
          "SecretEvalQuestionZulu",
          "SecretEvalAnswerZulu"
        )

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      html = render_click(view, "toggle_test_case", %{"id" => secret.id})

      refute html =~ "SecretEvalAnswerZulu"
      refute html =~ "SecretEvalChunkZulu"
    end

    test "rejects deleting a test case outside the allowed collections", %{conn: conn} do
      {secret, _chunks} = seed_test_case("other", "SecretEvalChunkZulu", "SecretEvalQuestionZulu")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      render_click(view, "eval_delete_test_case", %{"id" => secret.id})

      assert Repo.get(Evaluation.TestCase, secret.id)
    end

    test "still deletes a test case inside the allowed collections", %{conn: conn} do
      {allowed, _chunks} =
        seed_test_case("tenant-a", "AllowedEvalChunkZulu", "AllowedEvalQuestionZulu")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      render_click(view, "eval_delete_test_case", %{"id" => allowed.id})

      refute Repo.get(Evaluation.TestCase, allowed.id)
    end

    test "a malformed test case id is rejected instead of crashing", %{conn: conn} do
      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      render_click(view, "eval_delete_test_case", %{"id" => "not-a-uuid"})

      assert render(view) =~ "Evaluation"
    end

    test "hides and refuses to delete runs that are not scoped to the allowed collections",
         %{conn: conn} do
      global_run = insert_run(%{"mode" => "vector"})
      foreign_run = insert_run(%{"mode" => "vector", "collections" => ["other"]})

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      html = render_click(view, "eval_switch_view", %{"view" => "history"})

      refute html =~ "4242 test cases"

      render_click(view, "eval_delete_run", %{"id" => global_run.id})
      render_click(view, "eval_delete_run", %{"id" => foreign_run.id})

      assert Repo.get(Evaluation.Run, global_run.id)
      assert Repo.get(Evaluation.Run, foreign_run.id)
    end

    test "still shows and deletes a run scoped to the allowed collections", %{conn: conn} do
      run = insert_run(%{"mode" => "vector", "collections" => ["tenant-a"]})

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      html = render_click(view, "eval_switch_view", %{"view" => "history"})

      assert html =~ "4242 test cases"

      render_click(view, "eval_delete_run", %{"id" => run.id})

      refute Repo.get(Evaluation.Run, run.id)
    end

    # Running an evaluation is a retrieval primitive: without scoping every
    # test case searches every collection, so the run's stored results hand
    # back chunk ids the tenant may not read.
    test "a restricted evaluation run only retrieves from allowed collections", %{conn: conn} do
      # Both documents share the question's term, so an unscoped search
      # retrieves both; only the collection filter can keep the other
      # tenant's chunk out of the run's results.
      {_tc, _chunks} =
        seed_test_case("tenant-a", "AllowedEvalChunkZulu zulutopic", "zulutopic")

      {:ok, secret_doc} =
        Arcana.ingest("SecretEvalChunkZulu zulutopic", repo: Repo, collection: "other")

      secret_ids =
        Repo.all(from(c in Arcana.Chunk, where: c.document_id == ^secret_doc.id, select: c.id))

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      ids_before = run_ids()

      render_submit(view, "eval_run", %{"mode" => "vector", "retriever" => "pipeline"})
      render_until(view, "Evaluation completed!")

      run = run_created_since(ids_before)

      retrieved =
        run.results
        |> Map.values()
        |> Enum.flat_map(&(&1["retrieved_chunk_ids"] || []))

      assert secret_ids != []
      assert Enum.all?(secret_ids, &(&1 not in retrieved))
      assert run.config["collections"] == ["tenant-a"]
    end

    # Telemetry handlers are global, so an unfiltered progress handler
    # renders whatever question any other evaluation is on right now.
    test "the progress panel ignores telemetry from other evaluation runs", %{conn: conn} do
      seed_test_case("tenant-a", "AllowedEvalChunkZulu", "AllowedEvalQuestionZulu")
      put_arcana_env(:llm, "zai:test-stub")

      put_arcana_env(:loop_runner, fn ctx, _opts ->
        Process.sleep(300)

        {:ok,
         %Arcana.Loop.Context{
           question: ctx.question,
           answer: "stubbed",
           tool_history: [],
           iterations: 1,
           terminated_by: :answered,
           chunks: [],
           grounding: nil
         }}
      end)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      render_submit(view, "eval_run", %{"mode" => "vector", "retriever" => "loop"})

      :telemetry.execute(
        [:arcana, :evaluation, :test_case, :start],
        %{index: 1},
        %{
          run_id: Ecto.UUID.generate(),
          run_ref: make_ref(),
          index: 1,
          total: 1,
          question: "ForeignProgressQuestionZulu"
        }
      )

      refute render(view) =~ "ForeignProgressQuestionZulu"
      render_until(view, "Evaluation completed!")
    end

    test "a restricted Loop evaluation runs scoped and strict", %{conn: conn} do
      seed_test_case("tenant-a", "AllowedEvalChunkZulu", "AllowedEvalQuestionZulu")
      put_arcana_env(:llm, "zai:test-stub")

      test_pid = self()

      put_arcana_env(:loop_runner, fn ctx, opts ->
        send(test_pid, {:loop_scope, ctx.collections, opts[:search_opts]})

        {:ok,
         %Arcana.Loop.Context{
           question: ctx.question,
           answer: "stubbed",
           tool_history: [],
           iterations: 1,
           terminated_by: :answered,
           chunks: [],
           grounding: nil
         }}
      end)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/evaluation")

      render_submit(view, "eval_run", %{"mode" => "vector", "retriever" => "loop"})

      assert_receive {:loop_scope, collections, search_opts}, 2_000
      assert collections == ["tenant-a"]
      assert search_opts[:strict_collections] == true
      render_until(view, "Evaluation completed!")
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

    test "summarize refuses to run globally on a restricted dashboard", %{conn: conn} do
      # The other three actions were gated; summarize was added later and
      # wasn't, so an unscoped run summarized every tenant's communities.
      put_arcana_env(:llm, fn _p, _c, _o -> {:ok, "a summary"} end)
      mine = insert_dirty_community("tenant-a")
      theirs = insert_dirty_community("other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      # Assert the refusal, not the absence of a result. Sleeping and then
      # checking nothing happened passes just as well when the summarize did
      # start and is merely slower than the sleep, which on a loaded runner
      # is the likely outcome. The refusal is synchronous and flashes, so
      # there is a positive signal to assert instead.
      html = render_click(view, "summarize_communities", %{})

      assert html =~ "Select an allowed collection first",
             "expected a refusal, so nothing was ever dispatched"

      assert is_nil(Repo.get!(Community, theirs.id).summary),
             "summarized a collection the host never allowed"

      assert is_nil(Repo.get!(Community, mine.id).summary),
             "ran globally instead of refusing with no collection selected"
    end

    test "a forged summarize selection outside the allowed set does not stick", %{conn: conn} do
      put_arcana_env(:llm, fn _p, _c, _o -> {:ok, "a summary"} end)
      theirs = insert_dirty_community("other")
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      render_change(view, "select_summarize_communities_collection", %{"collection" => "other"})
      html = render_click(view, "summarize_communities", %{})

      # The forged name never sticks, so the selection is still empty and the
      # click is refused synchronously. Asserting the flash proves that,
      # where a sleep plus a nil check would also pass if the summarizer had
      # accepted "other" and simply not finished yet.
      assert html =~ "Select an allowed collection first",
             "the forged collection was accepted instead of refused"

      assert is_nil(Repo.get!(Community, theirs.id).summary),
             "a forged collection name reached the summarizer"
    end

    test "the summarize hint counts only allowed collections", %{conn: conn} do
      put_arcana_env(:llm, fn _p, _c, _o -> {:ok, "a summary"} end)
      insert_dirty_community("tenant-a")
      insert_dirty_community("other")

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      assert has_element?(view, ".arcana-summarize-hint", "1 communities need summarizing")
    end

    test "a forged selection outside the allowed set does not stick", %{conn: conn} do
      {:ok, _} = Collection.get_or_create("tenant-a", Repo)
      {:ok, _} = Collection.get_or_create("other", Repo)

      {:ok, view, _html} = conn |> restrict(["tenant-a"]) |> live("/scoped/maintenance")

      render_change(view, "select_reembed_collection", %{"collection" => "other"})

      html = render_click(view, "reembed", %{})
      refute html =~ "Re-embedding..."
    end

    # An allowed name with no collection row resolves to "no filter", which
    # would re-chunk and re-embed every document in the database. The
    # re-embed has to fail instead.
    test "a restricted re-embed fails closed when the allowed collection is missing",
         %{conn: conn} do
      {:ok, _} = Arcana.ingest("Other tenant content", repo: Repo, collection: "other")

      {:ok, view, _html} = conn |> restrict(["ghost"]) |> live("/scoped/maintenance")

      test_pid = self()

      put_arcana_env(:embedder, fn text ->
        send(test_pid, {:embedded, text})
        {:ok, List.duplicate(0.1, 384)}
      end)

      render_change(view, "select_reembed_collection", %{"collection" => "ghost"})
      render_click(view, "reembed", %{})

      # The stub embedder is the probe: unscoped, the re-embed walks every
      # chunk in the database and calls it.
      refute_receive {:embedded, _}, 500
      assert render(view) =~ "Maintenance"
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
