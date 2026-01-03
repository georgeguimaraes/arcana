defmodule Arcana.Graph.GraphBuilderTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.GraphBuilder

  @sample_chunks [
    %{id: "c1", text: "Sam Altman is the CEO of OpenAI."},
    %{id: "c2", text: "OpenAI developed GPT-4, a large language model."},
    %{id: "c3", text: "Microsoft invested $10 billion in OpenAI."}
  ]

  describe "build/3" do
    test "extracts entities from chunks" do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      assert is_list(graph_data.entities)
      assert graph_data.entities != []
    end

    test "extracts relationships between entities" do
      entity_extractor = fn _text, _opts ->
        {:ok,
         [
           %{name: "Sam Altman", type: "person"},
           %{name: "OpenAI", type: "organization"}
         ]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, [%{source: "Sam Altman", target: "OpenAI", type: "LEADS"}]}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      assert is_list(graph_data.relationships)
      assert graph_data.relationships != []
    end

    test "tracks entity-chunk mentions" do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      assert is_list(graph_data.mentions)
      # OpenAI appears in all 3 chunks
      openai_mentions =
        Enum.filter(graph_data.mentions, fn m -> m.entity_name == "OpenAI" end)

      assert length(openai_mentions) == 3
    end

    test "deduplicates entities across chunks" do
      entity_extractor = fn _text, _opts ->
        # Returns OpenAI from each chunk
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      # Should have only one OpenAI entity despite appearing in 3 chunks
      openai_entities =
        Enum.filter(graph_data.entities, fn e -> e.name == "OpenAI" end)

      assert length(openai_entities) == 1
    end

    test "handles extraction errors gracefully" do
      entity_extractor = fn _text, _opts ->
        {:error, :extraction_failed}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      # Should continue despite errors
      assert is_list(graph_data.entities)
    end

    test "generates unique IDs for entities" do
      entity_extractor = fn _text, _opts ->
        {:ok,
         [
           %{name: "OpenAI", type: "organization"},
           %{name: "GPT-4", type: "technology"}
         ]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      {:ok, graph_data} =
        GraphBuilder.build(@sample_chunks,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      ids = Enum.map(graph_data.entities, & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "build_from_text/3" do
    test "builds graph from single text" do
      entity_extractor = fn _text, _opts ->
        {:ok, [%{name: "OpenAI", type: "organization"}]}
      end

      relationship_extractor = fn _text, _entities, _opts ->
        {:ok, []}
      end

      text = "OpenAI is an AI research company."

      {:ok, graph_data} =
        GraphBuilder.build_from_text(text,
          entity_extractor: entity_extractor,
          relationship_extractor: relationship_extractor
        )

      assert length(graph_data.entities) == 1
    end
  end

  describe "merge/2" do
    test "merges two graph data structures" do
      graph1 = %{
        entities: [%{id: "1", name: "OpenAI", type: "organization"}],
        relationships: [],
        mentions: [%{entity_name: "OpenAI", chunk_id: "c1"}]
      }

      graph2 = %{
        entities: [%{id: "2", name: "GPT-4", type: "technology"}],
        relationships: [%{source: "OpenAI", target: "GPT-4", type: "DEVELOPS"}],
        mentions: [%{entity_name: "GPT-4", chunk_id: "c2"}]
      }

      merged = GraphBuilder.merge(graph1, graph2)

      assert length(merged.entities) == 2
      assert length(merged.relationships) == 1
      assert length(merged.mentions) == 2
    end

    test "deduplicates entities by name when merging" do
      graph1 = %{
        entities: [%{id: "1", name: "OpenAI", type: "organization"}],
        relationships: [],
        mentions: []
      }

      graph2 = %{
        entities: [%{id: "2", name: "OpenAI", type: "organization"}],
        relationships: [],
        mentions: []
      }

      merged = GraphBuilder.merge(graph1, graph2)

      # Should keep only one OpenAI
      assert length(merged.entities) == 1
    end
  end

  describe "to_query_graph/1" do
    test "converts builder output to GraphQuery format" do
      graph_data = %{
        entities: [
          %{id: "1", name: "OpenAI", type: "organization"},
          %{id: "2", name: "GPT-4", type: "technology"}
        ],
        relationships: [
          %{source: "OpenAI", target: "GPT-4", type: "DEVELOPS"}
        ],
        mentions: [
          %{entity_name: "OpenAI", chunk_id: "c1"},
          %{entity_name: "GPT-4", chunk_id: "c1"}
        ]
      }

      chunks = [%{id: "c1", text: "OpenAI develops GPT-4"}]

      query_graph = GraphBuilder.to_query_graph(graph_data, chunks)

      assert is_map(query_graph.entities)
      assert is_list(query_graph.relationships)
      assert is_map(query_graph.adjacency)
    end
  end
end
