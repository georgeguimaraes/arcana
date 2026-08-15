defmodule Arcana.GraphIntegrationTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Entity, EntityMention, Relationship}

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

  describe "config/0" do
    test "includes graph configuration" do
      config = Arcana.config()

      assert Map.has_key?(config, :graph)
      assert is_map(config.graph)
      assert Map.has_key?(config.graph, :enabled)
    end
  end
end
