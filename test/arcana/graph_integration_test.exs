defmodule Arcana.GraphIntegrationTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship}

  # Scoped to the collection under test: the documents table is shared with
  # every other test in this file, so a global count asserts something no
  # single test controls.
  defp documents_in(collection_name) do
    Repo.all(
      from(d in Arcana.Document,
        join: c in Arcana.Collection,
        on: c.id == d.collection_id,
        where: c.name == ^collection_name
      )
    )
  end

  defp create_collection(name) do
    %Arcana.Collection{}
    |> Arcana.Collection.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp create_document(collection, attrs \\ %{}) do
    %Arcana.Document{}
    |> Arcana.Document.changeset(
      Map.merge(
        %{
          title: "test-doc",
          source: "test",
          content: "Test document content",
          collection_id: collection.id,
          status: :completed
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp create_chunk(document, text) do
    %Arcana.Chunk{}
    |> Arcana.Chunk.changeset(%{
      text: text,
      document_id: document.id,
      embedding: Enum.map(1..384, fn _ -> :rand.uniform() end)
    })
    |> Repo.insert!()
  end

  defp create_entity(collection, name, type \\ "person") do
    %Entity{}
    |> Entity.changeset(%{name: name, type: type, collection_id: collection.id})
    |> Repo.insert!()
  end

  defp create_mention(entity, chunk) do
    %EntityMention{}
    |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
    |> Repo.insert!()
  end

  defp create_relationship(source, target, type \\ "knows") do
    %Relationship{}
    |> Relationship.changeset(%{source_id: source.id, target_id: target.id, type: type})
    |> Repo.insert!()
  end

  describe "graph_enabled?/1" do
    test "returns false when no option and config disabled" do
      refute Arcana.graph_enabled?([])
    end

    test "returns true when graph: true option provided" do
      assert Arcana.graph_enabled?(graph: true)
    end

    test "returns false when graph: false option provided" do
      refute Arcana.graph_enabled?(graph: false)
    end
  end

  describe "ingest/2 with graph: true" do
    test "creates entities from extracted text" do
      # Mock entity extractor that returns predictable entities
      entity_extractor = fn text, _opts ->
        cond do
          text =~ "OpenAI" and text =~ "Sam Altman" ->
            {:ok,
             [
               %{name: "OpenAI", type: "organization"},
               %{name: "Sam Altman", type: "person"}
             ]}

          text =~ "OpenAI" ->
            {:ok, [%{name: "OpenAI", type: "organization"}]}

          text =~ "Sam Altman" ->
            {:ok, [%{name: "Sam Altman", type: "person"}]}

          true ->
            {:ok, []}
        end
      end

      {:ok, document} =
        Arcana.ingest(
          "Sam Altman leads OpenAI, an AI research company.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "graph-test"
        )

      assert document.status == :completed

      # Verify entities were created
      entities = Repo.all(Entity)
      entity_names = Enum.map(entities, & &1.name) |> Enum.sort()

      assert "OpenAI" in entity_names
      assert "Sam Altman" in entity_names

      # Verify entity mentions link entities to chunks
      mentions = Repo.all(EntityMention)
      refute Enum.empty?(mentions)

      # Each mention should reference a valid entity and chunk
      for mention <- mentions do
        assert Repo.get(Entity, mention.entity_id) != nil
        assert Repo.get(Arcana.Chunk, mention.chunk_id) != nil
      end
    end

    test "creates relationships when relationship extractor is provided" do
      entity_extractor = fn _text, _opts ->
        {:ok,
         [
           %{name: "OpenAI", type: "organization"},
           %{name: "Sam Altman", type: "person"}
         ]}
      end

      relationship_extractor = fn _text, entities, _opts ->
        if length(entities) >= 2 do
          {:ok,
           [
             %{
               source: "Sam Altman",
               target: "OpenAI",
               type: "LEADS",
               description: "CEO relationship",
               strength: 9
             }
           ]}
        else
          {:ok, []}
        end
      end

      {:ok, _document} =
        Arcana.ingest(
          "Sam Altman leads OpenAI.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor,
          collection: "graph-rel-test"
        )

      # Verify relationship was created
      relationships = Repo.all(Relationship)
      refute Enum.empty?(relationships)

      rel = hd(relationships)
      assert rel.type == "LEADS"
      assert rel.strength == 9
    end

    test "deduplicates entities by name within collection" do
      entity_extractor = fn _text, _opts ->
        # Return duplicate entity names
        {:ok,
         [
           %{name: "OpenAI", type: "organization"},
           %{name: "OpenAI", type: "organization"}
         ]}
      end

      {:ok, _document} =
        Arcana.ingest(
          "OpenAI is mentioned twice. OpenAI again.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "dedup-test"
        )

      # Should only have one OpenAI entity
      entities = Repo.all(from(e in Entity, where: e.name == "OpenAI"))
      assert length(entities) == 1
    end

    test "rebuilding the graph over unchanged chunks does not duplicate mentions" do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      {:ok, document} =
        Arcana.ingest(
          "OpenAI builds AI systems.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "mention-dedup-test"
        )

      mentions_before = Repo.aggregate(EntityMention, :count)
      assert mentions_before > 0

      # Rebuild over the same chunk records, like mix arcana.graph.rebuild
      # or a re-ingest over unchanged chunks would.
      chunks = Repo.all(from(c in Arcana.Chunk, where: c.document_id == ^document.id))
      {:ok, collection} = Arcana.Collection.get_or_create("mention-dedup-test", Repo)

      {:ok, _} =
        Arcana.Graph.build_and_persist(chunks, collection, Repo,
          entity_extractor: entity_extractor
        )

      assert Repo.aggregate(EntityMention, :count) == mentions_before
    end

    test "continues even if entity extraction fails for a chunk" do
      call_count = :counters.new(1, [])

      entity_extractor = fn _text, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        # Fail on first call, succeed on others
        if count == 0 do
          {:error, :extraction_failed}
        else
          {:ok, [%{name: "TestEntity", type: "concept"}]}
        end
      end

      {:ok, document} =
        Arcana.ingest(
          "This is test content that will be chunked. More content here to ensure multiple chunks.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "error-handling-test"
        )

      assert document.status == :completed
    end

    # NBSP arrives with any HTML/PDF-derived text. Elixir's String.trim/1
    # strips it, Postgres' btrim doesn't, so the entity used to miss itself
    # on the second chunk's upsert and violate the name unique index.
    test "handles an entity whose name carries an NBSP across several chunks" do
      name = "Delivery\u{a0}"
      extractor = fn _text, _opts -> {:ok, [%{name: name, type: "concept"}]} end

      {:ok, document} =
        Arcana.ingest(
          String.duplicate("Delivery terms apply to every order placed here. ", 20),
          repo: Repo,
          graph: true,
          entity_extractor: extractor,
          collection: "nbsp-chunks",
          chunk_size: 100,
          chunk_overlap: 0
        )

      assert document.chunk_count > 1
      assert Repo.aggregate(from(e in Entity, where: e.name == ^name), :count) == 1
    end

    test "re-ingesting a document whose entity name carries an NBSP reuses the entity" do
      name = "Delivery\u{a0}"
      extractor = fn _text, _opts -> {:ok, [%{name: name, type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        collection: "nbsp-reingest"
      ]

      assert {:ok, _} = Arcana.ingest("shipping policy v1", opts)
      assert {:ok, _} = Arcana.ingest("shipping policy v2", opts)

      assert Repo.aggregate(from(e in Entity, where: e.name == ^name), :count) == 1
    end

    test "marks the document failed when the graph build blows up" do
      assert_raise RuntimeError, fn ->
        Arcana.ingest("boom content",
          repo: Repo,
          graph: true,
          entity_extractor: fn _text, _opts -> {:ok, [%{name: "Boom", type: "concept"}]} end,
          graph_store: Arcana.RaisingGraphStore,
          collection: "graph-build-blows-up"
        )
      end

      # A half-built graph must not leave a document stuck in :processing
      assert [document] = Repo.all(Arcana.Document)
      assert document.status == :failed
    end

    # Extraction runs inside Task.async_stream, so a raising extractor used
    # to take the ingest process down through the task's link exit signal
    # instead of unwinding through the rescue that marks the document
    # :failed. That is reachable from the shipped default: NERServing
    # raises outright when Bumblebee isn't loaded, and the LLM extractors
    # raise KeyError with no LLM configured.
    for kind <- [:raises, :throws, :exits] do
      test "marks the document failed when the entity extractor #{kind}" do
        collection = "graph-extractor-#{unquote(kind)}"

        boom = fn ->
          case unquote(kind) do
            :raises -> raise "extractor exploded"
            :throws -> throw(:extractor_threw)
            :exits -> exit(:extractor_exited)
          end
        end

        parent = self()

        {pid, ref} =
          spawn_monitor(fn ->
            receive do
              :go -> :ok
            end

            Arcana.ingest("boom content",
              repo: Repo,
              graph: true,
              entity_extractor: fn _text, _opts -> boom.() end,
              collection: collection
            )

            send(parent, :ingest_returned)
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, pid)
        send(pid, :go)

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
        refute_received :ingest_returned

        assert [document] = documents_in(collection)
        assert document.status == :failed
      end
    end
  end

  describe "search/2 with graph: true" do
    setup do
      # Set up test data with entities and mentions
      entity_extractor = fn _text, _opts ->
        {:ok,
         [
           %{name: "Elixir", type: "technology"},
           %{name: "Phoenix", type: "technology"}
         ]}
      end

      {:ok, doc} =
        Arcana.ingest(
          "Elixir is a functional programming language. Phoenix is a web framework for Elixir.",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "search-graph-test"
        )

      %{document: doc}
    end

    test "enhances search with graph results when entities are found", %{document: doc} do
      # Mock extractor for search query
      entity_extractor = fn query, _opts ->
        if query =~ "Elixir" do
          {:ok, [%{name: "Elixir", type: "technology"}]}
        else
          {:ok, []}
        end
      end

      {:ok, results} =
        Arcana.search("What is Elixir?",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "search-graph-test"
        )

      refute Enum.empty?(results)

      # Results should include chunks from the ingested document
      assert Enum.any?(results, fn r -> r.document_id == doc.id end)
    end

    test "falls back to vector search when no entities found" do
      entity_extractor = fn _query, _opts ->
        {:ok, []}
      end

      {:ok, results} =
        Arcana.search("functional programming",
          repo: Repo,
          graph: true,
          entity_extractor: entity_extractor,
          collection: "search-graph-test"
        )

      # Should still return results from vector search
      refute Enum.empty?(results)
    end

    test "works without graph option (default behavior)" do
      {:ok, results} =
        Arcana.search("Elixir programming",
          repo: Repo,
          collection: "search-graph-test"
        )

      refute Enum.empty?(results)
    end

    test "does not duplicate chunks that appear in both vector and graph results when doing hybrid search" do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "Elixir", type: "technology"}]}
      end

      {:ok, results} =
        Arcana.search("Elixir",
          repo: Repo,
          graph: true,
          mode: :hybrid,
          entity_extractor: entity_extractor,
          collection: "search-graph-test"
        )

      assert length(results) == 1
    end
  end

  describe "search/2 with graph_depth" do
    # Entities: Alice -- Bob -- Carol (chained relationships) in "depth-test",
    # plus Dave in "depth-other" linked to Alice across collections. Each
    # entity is mentioned by exactly one chunk. The query matches only Alice
    # (fixed NER matcher) and threshold: 0.99 suppresses vector results, so
    # everything retrieved comes from the graph side.
    setup do
      collection = create_collection("depth-test")
      other_collection = create_collection("depth-other")

      document = create_document(collection, %{source_id: "scoped-source"})
      other_document = create_document(other_collection)

      chunk_a = create_chunk(document, "Chunk about Alice")
      chunk_b = create_chunk(document, "Chunk about Bob")
      chunk_c = create_chunk(document, "Chunk about Carol")
      chunk_d = create_chunk(other_document, "Chunk about Dave")

      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")
      carol = create_entity(collection, "Carol")
      dave = create_entity(other_collection, "Dave")

      create_mention(alice, chunk_a)
      create_mention(bob, chunk_b)
      create_mention(carol, chunk_c)
      create_mention(dave, chunk_d)

      create_relationship(alice, bob)
      create_relationship(bob, carol)
      create_relationship(alice, dave)

      opts = [
        repo: Repo,
        graph: true,
        collection: "depth-test",
        threshold: 0.99,
        entity_matcher: :ner,
        entity_extractor: fn _query, _opts ->
          {:ok, [%{name: "Alice", type: "person"}]}
        end
      ]

      %{
        opts: opts,
        collection: collection,
        bob: bob,
        chunk_a: chunk_a,
        chunk_b: chunk_b,
        chunk_c: chunk_c,
        chunk_d: chunk_d
      }
    end

    test "default depth 0 returns only direct-mention chunks", ctx do
      {:ok, results} = Arcana.search("Alice", ctx.opts)

      ids = Enum.map(results, & &1.id)
      assert ids == [ctx.chunk_a.id]
    end

    test "graph_depth: 0 returns exactly the default results", ctx do
      {:ok, default_results} = Arcana.search("Alice", ctx.opts)
      {:ok, depth_zero_results} = Arcana.search("Alice", Keyword.put(ctx.opts, :graph_depth, 0))

      assert depth_zero_results == default_results
    end

    test "graph results honor :source_id at every hop", %{opts: opts} = ctx do
      # Bob (a hop-1 neighbor of Alice) is also mentioned by a chunk in a
      # different source; a source-scoped search must not surface it
      other_source_doc = create_document(ctx.collection, %{source_id: "other-source"})
      foreign_chunk = create_chunk(other_source_doc, "Bob in another source")
      create_mention(ctx.bob, foreign_chunk)

      scoped_opts =
        opts
        |> Keyword.put(:graph_depth, 1)
        |> Keyword.put(:source_id, "scoped-source")

      {:ok, results} = Arcana.search("Alice", scoped_opts)
      ids = Enum.map(results, & &1.id)

      assert ctx.chunk_a.id in ids
      refute foreign_chunk.id in ids
    end

    test "graph_depth: 1 pulls in neighbor chunks ranked below direct matches", ctx do
      {:ok, results} = Arcana.search("Alice", Keyword.put(ctx.opts, :graph_depth, 1))

      assert [first, second] = results
      assert first.id == ctx.chunk_a.id
      assert second.id == ctx.chunk_b.id
      assert first.score > second.score
      refute ctx.chunk_c.id in Enum.map(results, & &1.id)
    end

    test "graph_depth: 2 reaches two-hop neighbors", ctx do
      {:ok, results} = Arcana.search("Alice", Keyword.put(ctx.opts, :graph_depth, 2))

      assert Enum.map(results, & &1.id) == [ctx.chunk_a.id, ctx.chunk_b.id, ctx.chunk_c.id]
    end

    test "expansion respects collection scoping", ctx do
      {:ok, results} = Arcana.search("Alice", Keyword.put(ctx.opts, :graph_depth, 2))

      ids = Enum.map(results, & &1.id)
      # in-collection neighbors came in, the cross-collection one did not
      assert ctx.chunk_b.id in ids
      refute ctx.chunk_d.id in ids
    end

    test "global query_depth config applies and per-call graph_depth wins", ctx do
      put_arcana_env(:graph, query_depth: 1)

      {:ok, global_results} = Arcana.search("Alice", ctx.opts)
      assert Enum.map(global_results, & &1.id) == [ctx.chunk_a.id, ctx.chunk_b.id]

      {:ok, override_results} = Arcana.search("Alice", Keyword.put(ctx.opts, :graph_depth, 0))
      assert Enum.map(override_results, & &1.id) == [ctx.chunk_a.id]
    end
  end

  describe "delete/2 with graph enabled" do
    test "sweeps zero-mention entities in the document's collection and dirties overlapping communities" do
      extractor = fn text, _opts ->
        cond do
          text =~ "alpha" ->
            {:ok, [%{name: "Alpha", type: "concept"}, %{name: "Shared", type: "concept"}]}

          text =~ "shared" ->
            {:ok, [%{name: "Shared", type: "concept"}]}

          text =~ "beta" ->
            {:ok, [%{name: "Beta", type: "concept"}]}

          true ->
            {:ok, []}
        end
      end

      opts = [repo: Repo, graph: true, entity_extractor: extractor]

      {:ok, doc1} = Arcana.ingest("alpha content", opts ++ [collection: "sweep-a"])
      {:ok, _doc2} = Arcana.ingest("shared content", opts ++ [collection: "sweep-a"])
      {:ok, _doc3} = Arcana.ingest("beta content", opts ++ [collection: "sweep-b"])

      alpha = Repo.one!(from(e in Entity, where: e.name == "Alpha"))
      shared = Repo.one!(from(e in Entity, where: e.name == "Shared"))
      beta = Repo.one!(from(e in Entity, where: e.name == "Beta"))

      relationship =
        %Relationship{}
        |> Relationship.changeset(%{source_id: alpha.id, target_id: shared.id, type: "RELATED"})
        |> Repo.insert!()

      alpha_community = insert_community(alpha.collection_id, [alpha.id])
      shared_community = insert_community(shared.collection_id, [shared.id])
      beta_community = insert_community(beta.collection_id, [beta.id])

      :ok = Arcana.delete(doc1.id, repo: Repo, graph: true)

      # Alpha lost its only mention and is swept; its relationships cascade
      assert Repo.get(Entity, alpha.id) == nil
      assert Repo.get(Relationship, relationship.id) == nil

      # Shared still has a mention in doc2; Beta lives in another collection
      assert Repo.get(Entity, shared.id)
      assert Repo.get(Entity, beta.id)

      # Only communities overlapping the swept entities get marked dirty
      assert Repo.get!(Community, alpha_community.id).dirty
      refute Repo.get!(Community, shared_community.id).dirty
      refute Repo.get!(Community, beta_community.id).dirty

      # ...and they drop the swept ids, so entity_count stops counting
      # entities that no longer exist
      assert Repo.get!(Community, alpha_community.id).entity_ids == []
      assert Repo.get!(Community, shared_community.id).entity_ids == [shared.id]
    end

    test "replace: true sweeps entities stranded by the replaced document" do
      extractor = fn text, _opts ->
        cond do
          text =~ "v1" -> {:ok, [%{name: "OldEntity", type: "concept"}]}
          text =~ "v2" -> {:ok, [%{name: "NewEntity", type: "concept"}]}
          true -> {:ok, []}
        end
      end

      opts = [
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        collection: "replace-sweep",
        source_id: "doc-1",
        replace: true
      ]

      {:ok, _v1} = Arcana.ingest("v1 content", opts)
      {:ok, _v2} = Arcana.ingest("v2 content", opts)

      names = Repo.all(Entity) |> Enum.map(& &1.name)
      assert "NewEntity" in names
      refute "OldEntity" in names
    end

    test "propagates a failing sweep after the document is already deleted" do
      extractor = fn _text, _opts -> {:ok, [%{name: "Delta", type: "concept"}]} end

      {:ok, doc} =
        Arcana.ingest("delta content",
          repo: Repo,
          graph: true,
          entity_extractor: extractor,
          graph_store: Arcana.FailingSweepGraphStore,
          collection: "sweep-fails"
        )

      assert {:error, {:sweep_failed, :sweep_boom}} =
               Arcana.delete(doc.id,
                 repo: Repo,
                 graph: true,
                 graph_store: Arcana.FailingSweepGraphStore
               )

      # The document is gone regardless: only the cleanup failed
      assert Repo.get(Arcana.Document, doc.id) == nil
    end

    test "build and sweep use the same per-call graph store" do
      extractor = fn _text, _opts -> {:ok, [%{name: "Epsilon", type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        entity_extractor: extractor,
        graph_store: {Arcana.SpyGraphStore, notify: self()},
        collection: "spy-store",
        source_id: "spied",
        replace: true
      ]

      {:ok, _doc} = Arcana.ingest("epsilon content", opts)

      # Persistence must land on the opts-provided backend, not the
      # configured default, or the sweep below would target a graph the
      # build never wrote to.
      assert_received {:spy_graph_store, {:persist_entities, _collection_id, ["Epsilon"]}}
      assert_received {:spy_graph_store, {:persist_mentions, 1}}
      assert_received {:spy_graph_store, {:sweep_orphans, _collection_id}}

      # Nothing reached the Ecto store
      assert Repo.all(Entity) == []
    end

    test "a store predating sweep_orphans/2 still deletes cleanly" do
      extractor = fn _text, _opts -> {:ok, [%{name: "Zeta", type: "concept"}]} end

      {:ok, doc} =
        Arcana.ingest("zeta content",
          repo: Repo,
          graph: true,
          entity_extractor: extractor,
          graph_store: Arcana.LegacyGraphStore,
          collection: "legacy-store"
        )

      # sweep_orphans/2 is optional: a store that can't sweep just doesn't,
      # exactly as delete/2 behaved before the callback existed.
      assert :ok =
               Arcana.delete(doc.id,
                 repo: Repo,
                 graph: true,
                 graph_store: Arcana.LegacyGraphStore
               )

      assert Repo.get(Arcana.Document, doc.id) == nil
    end

    test "leaves the graph alone when graph is not enabled" do
      extractor = fn _text, _opts -> {:ok, [%{name: "Gamma", type: "concept"}]} end

      {:ok, doc} =
        Arcana.ingest("gamma content",
          repo: Repo,
          graph: true,
          entity_extractor: extractor,
          collection: "sweep-off"
        )

      gamma = Repo.one!(from(e in Entity, where: e.name == "Gamma"))

      :ok = Arcana.delete(doc.id, repo: Repo)

      # Entity survives (stranded, but sweeping requires graph enabled)
      assert Repo.get(Entity, gamma.id)
    end
  end

  describe "config/0" do
    test "includes graph configuration" do
      config = Arcana.config()

      assert Map.has_key?(config, :graph)
      assert is_map(config.graph)
      assert Map.has_key?(config.graph, :enabled)
    end
  end

  defp insert_community(collection_id, entity_ids) do
    %Community{}
    |> Community.changeset(%{
      level: 0,
      entity_ids: entity_ids,
      dirty: false,
      summary: "existing summary",
      collection_id: collection_id
    })
    |> Repo.insert!()
  end
end
