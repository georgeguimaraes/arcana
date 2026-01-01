defmodule Arcana.Graph.GraphBuilder do
  @moduledoc """
  Builds knowledge graph data from document chunks.

  GraphBuilder orchestrates entity extraction, relationship extraction, and
  mention tracking to create a knowledge graph structure from text.

  ## Usage

  GraphBuilder is designed to integrate optionally into the ingest pipeline:

      # During ingest (when graph: true option is passed)
      chunks = Chunker.chunk(text, opts)
      {:ok, graph_data} = GraphBuilder.build(chunks,
        entity_extractor: &Arcana.Graph.EntityExtractor.NER.extract/2,
        relationship_extractor: &RelationshipExtractor.extract/3
      )

      # Convert to queryable format
      graph = GraphBuilder.to_query_graph(graph_data, chunks)

  ## Output Structure

  The builder outputs a map with:

      %{
        entities: [%{id: "...", name: "...", type: :atom}],
        relationships: [%{source: "...", target: "...", type: "..."}],
        mentions: [%{entity_name: "...", chunk_id: "..."}]
      }

  This intermediate format can be persisted to a database or converted
  to the in-memory format used by `GraphQuery`.

  """

  alias Arcana.Graph.GraphQuery

  @type chunk :: %{id: String.t(), text: String.t()}
  @type entity :: %{id: String.t(), name: String.t(), type: atom()}
  @type relationship :: %{source: String.t(), target: String.t(), type: String.t()}
  @type mention :: %{entity_name: String.t(), chunk_id: String.t()}

  @type graph_data :: %{
          entities: [entity()],
          relationships: [relationship()],
          mentions: [mention()]
        }

  @doc """
  Builds graph data from a list of chunks.

  Extracts entities and relationships from each chunk, tracking which
  entities appear in which chunks (mentions).

  ## Options

    - `:entity_extractor` - Function `(text, opts) -> {:ok, entities} | {:error, reason}`
    - `:relationship_extractor` - Function `(text, entities, opts) -> {:ok, rels} | {:error, reason}`

  ## Returns

    - `{:ok, graph_data}` - Successfully built graph data
    - `{:error, reason}` - If all extractions fail

  """
  @spec build([chunk()], keyword()) :: {:ok, graph_data()} | {:error, term()}
  def build(chunks, opts) do
    entity_extractor = Keyword.fetch!(opts, :entity_extractor)
    relationship_extractor = Keyword.fetch!(opts, :relationship_extractor)

    {entities, mentions, relationships} =
      chunks
      |> Enum.reduce({[], [], []}, fn chunk, {ent_acc, ment_acc, rel_acc} ->
        process_chunk(chunk, entity_extractor, relationship_extractor, ent_acc, ment_acc, rel_acc)
      end)

    # Deduplicate entities by name
    deduplicated_entities = deduplicate_entities(entities)

    # Assign IDs to entities
    entities_with_ids = assign_entity_ids(deduplicated_entities)

    {:ok,
     %{
       entities: entities_with_ids,
       relationships: relationships,
       mentions: mentions
     }}
  end

  @doc """
  Builds graph data from a single text string.

  Convenience function for processing a single document without chunks.
  """
  @spec build_from_text(String.t(), keyword()) :: {:ok, graph_data()} | {:error, term()}
  def build_from_text(text, opts) do
    chunk = %{id: generate_id(), text: text}
    build([chunk], opts)
  end

  @doc """
  Merges two graph data structures.

  Combines entities (deduplicating by name), relationships, and mentions.
  Useful for incremental graph building across multiple documents.
  """
  @spec merge(graph_data(), graph_data()) :: graph_data()
  def merge(graph1, graph2) do
    combined_entities = graph1.entities ++ graph2.entities
    deduplicated = deduplicate_entities(combined_entities)

    %{
      entities: deduplicated,
      relationships: graph1.relationships ++ graph2.relationships,
      mentions: graph1.mentions ++ graph2.mentions
    }
  end

  @doc """
  Converts builder output to the format used by GraphQuery.

  Takes the graph data and original chunks to build an indexed
  graph structure suitable for querying.
  """
  @spec to_query_graph(graph_data(), [chunk()]) :: GraphQuery.graph()
  def to_query_graph(graph_data, chunks) do
    # Build entity ID lookup
    entity_ids = build_entity_id_map(graph_data.entities)

    # Convert relationships to use entity IDs
    relationships =
      graph_data.relationships
      |> Enum.map(fn rel ->
        %{
          source_id: Map.get(entity_ids, rel.source),
          target_id: Map.get(entity_ids, rel.target),
          type: rel.type
        }
      end)
      |> Enum.filter(fn rel -> rel.source_id != nil and rel.target_id != nil end)

    # Build chunks with entity_ids from mentions
    chunks_with_entities =
      chunks
      |> Enum.map(fn chunk ->
        chunk_mentions =
          Enum.filter(graph_data.mentions, fn m -> m.chunk_id == chunk.id end)

        entity_ids_for_chunk =
          chunk_mentions
          |> Enum.map(fn m -> Map.get(entity_ids, m.entity_name) end)
          |> Enum.reject(&is_nil/1)

        Map.put(chunk, :entity_ids, entity_ids_for_chunk)
      end)

    # Use GraphQuery.build_graph to create indexed structure
    GraphQuery.build_graph(
      graph_data.entities,
      relationships,
      chunks_with_entities,
      []
    )
  end

  # Private functions

  defp process_chunk(chunk, entity_extractor, relationship_extractor, ent_acc, ment_acc, rel_acc) do
    case entity_extractor.(chunk.text, []) do
      {:ok, entities} ->
        # Track mentions
        new_mentions =
          Enum.map(entities, fn e ->
            %{entity_name: e.name, chunk_id: chunk.id}
          end)

        # Extract relationships
        new_relationships = extract_relationships(chunk.text, entities, relationship_extractor)

        {ent_acc ++ entities, ment_acc ++ new_mentions, rel_acc ++ new_relationships}

      {:error, _} ->
        # Continue despite errors
        {ent_acc, ment_acc, rel_acc}
    end
  end

  defp extract_relationships(text, entities, relationship_extractor) do
    case relationship_extractor.(text, entities, []) do
      {:ok, relationships} -> relationships
      {:error, _} -> []
    end
  end

  defp deduplicate_entities(entities) do
    entities
    |> Enum.reduce(%{}, fn entity, acc ->
      name = entity.name

      if Map.has_key?(acc, name) do
        # Keep existing, could merge descriptions here
        acc
      else
        Map.put(acc, name, entity)
      end
    end)
    |> Map.values()
  end

  defp assign_entity_ids(entities) do
    entities
    |> Enum.with_index()
    |> Enum.map(fn {entity, idx} ->
      id = Map.get(entity, :id, "entity_#{idx}")
      Map.put(entity, :id, id)
    end)
  end

  defp build_entity_id_map(entities) do
    Map.new(entities, fn e -> {e.name, e.id} end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
