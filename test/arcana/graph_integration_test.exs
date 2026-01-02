defmodule Arcana.GraphIntegrationTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Entity, EntityMention, Relationship}

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
               %{name: "OpenAI", type: :organization},
               %{name: "Sam Altman", type: :person}
             ]}

          text =~ "OpenAI" ->
            {:ok, [%{name: "OpenAI", type: :organization}]}

          text =~ "Sam Altman" ->
            {:ok, [%{name: "Sam Altman", type: :person}]}

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
           %{name: "OpenAI", type: :organization},
           %{name: "Sam Altman", type: :person}
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
           %{name: "OpenAI", type: :organization},
           %{name: "OpenAI", type: :organization}
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

    test "continues even if entity extraction fails for a chunk" do
      call_count = :counters.new(1, [])

      entity_extractor = fn _text, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        # Fail on first call, succeed on others
        if count == 0 do
          {:error, :extraction_failed}
        else
          {:ok, [%{name: "TestEntity", type: :concept}]}
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
           %{name: "Elixir", type: :technology},
           %{name: "Phoenix", type: :technology}
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
          {:ok, [%{name: "Elixir", type: :technology}]}
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
