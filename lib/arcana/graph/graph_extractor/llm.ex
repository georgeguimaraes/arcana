defmodule Arcana.Graph.GraphExtractor.LLM do
  @moduledoc """
  LLM-based combined entity and relationship extraction.

  Extracts both entities and relationships in a single LLM call,
  which is more efficient than separate extractors.

  ## Usage

      extractor = {Arcana.Graph.GraphExtractor.LLM, llm: my_llm}
      {:ok, result} = GraphExtractor.extract(extractor, text)

  ## Configuration

      config :arcana, :graph,
        extractor: Arcana.Graph.GraphExtractor.LLM

  The LLM is automatically injected from the global `:arcana, :llm` config.

  ## Options

    - `:llm` - Required. An LLM tuple like `{"openai:gpt-4", api_key: "..."}` or function

  """

  @behaviour Arcana.Graph.GraphExtractor

  @default_types [
    :person,
    :organization,
    :location,
    :event,
    :concept,
    :technology,
    :role,
    :publication,
    :media,
    :award,
    :standard,
    :language
  ]

  @impl true
  def extract(text, opts) when is_binary(text) do
    llm = Keyword.fetch!(opts, :llm)
    prompt = build_prompt(text)

    :telemetry.span([:arcana, :graph, :extraction], %{text: text}, fn ->
      result =
        case Arcana.LLM.complete(llm, prompt, [], system_prompt: system_prompt()) do
          {:ok, response} ->
            parse_and_validate(response)

          {:error, reason} ->
            {:error, reason}
        end

      metadata =
        case result do
          {:ok, data} ->
            %{entity_count: length(data.entities), relationship_count: length(data.relationships)}

          {:error, _} ->
            %{entity_count: 0, relationship_count: 0}
        end

      {result, metadata}
    end)
  end

  @doc """
  Builds the prompt for combined entity and relationship extraction.
  """
  @spec build_prompt(String.t()) :: String.t()
  def build_prompt(text) do
    type_list = Enum.map_join(@default_types, ", ", &to_string/1)

    """
    Extract entities and relationships from the following text.

    ## Text to analyze:
    #{text}

    ## Entity types to extract:
    #{type_list}

    ## Instructions:
    1. Identify all significant named entities in the text
    2. Classify each entity into one of the types listed above (use "other" if none fit)
    3. Identify meaningful relationships between the entities
    4. Use relationship types in UPPER_SNAKE_CASE (e.g., WORKS_AT, FOUNDED, LEADS, LOCATED_IN)
    5. Rate relationship strength from 1-10 based on how explicit and central it is

    ## Type definitions:
    - person: Individual people (e.g., "Sam Altman", "Dr. Jane Smith")
    - organization: Companies, institutions, groups (e.g., "OpenAI", "FDA")
    - location: Geographic places, facilities (e.g., "San Francisco", "MIT Campus")
    - event: Named events, conferences (e.g., "World War II", "GPT-4 Launch")
    - concept: Abstract ideas, methodologies (e.g., "Machine Learning", "Agile")
    - technology: Products, tools, software (e.g., "GPT-4", "PostgreSQL")
    - role: Job titles, positions (e.g., "CEO", "Software Engineer")
    - publication: Papers, books, articles (e.g., "Attention Is All You Need")
    - media: Movies, songs, artworks (e.g., "The Matrix")
    - award: Awards, certifications (e.g., "Nobel Prize", "ISO 9001")
    - standard: Specifications, protocols (e.g., "RFC 2616", "WCAG 2.1")
    - language: Programming or natural languages (e.g., "Python", "Mandarin")

    ## Output format:
    Return a JSON object with two arrays:

    ```json
    {
      "entities": [
        {"name": "Entity Name", "type": "type", "description": "Brief context"}
      ],
      "relationships": [
        {"source": "Source Entity", "target": "Target Entity", "type": "RELATIONSHIP_TYPE", "description": "Brief description", "strength": 8}
      ]
    }
    ```

    Return only the JSON object, no other text.
    """
  end

  defp system_prompt do
    """
    You are a knowledge graph construction assistant. Your task is to extract
    named entities and their relationships from text. Be precise and extract
    only clearly identifiable entities and relationships that are stated or
    strongly implied. Always return valid JSON.
    """
  end

  defp parse_and_validate(response) do
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"entities" => entities, "relationships" => relationships}}
      when is_list(entities) and is_list(relationships) ->
        normalized_entities = Enum.map(entities, &normalize_entity/1)
        entity_names = MapSet.new(normalized_entities, & &1.name)

        validated_relationships =
          relationships
          |> Enum.map(&normalize_relationship/1)
          |> Enum.filter(&valid_relationship?(&1, entity_names))

        {:ok, %{entities: normalized_entities, relationships: validated_relationships}}

      {:ok, _} ->
        {:error, {:json_parse_error, "Expected object with 'entities' and 'relationships' arrays"}}

      {:error, error} ->
        {:error, {:json_parse_error, error}}
    end
  end

  defp normalize_entity(entity) when is_map(entity) do
    %{
      name: Map.get(entity, "name"),
      type: normalize_type(Map.get(entity, "type")),
      description: Map.get(entity, "description")
    }
  end

  defp normalize_type(nil), do: "other"

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[^a-z_]/, "")
  end

  defp normalize_type(_), do: "other"

  defp normalize_relationship(rel) when is_map(rel) do
    %{
      source: Map.get(rel, "source"),
      target: Map.get(rel, "target"),
      type: normalize_relationship_type(Map.get(rel, "type")),
      description: Map.get(rel, "description"),
      strength: normalize_strength(Map.get(rel, "strength"))
    }
  end

  defp normalize_relationship_type(nil), do: "RELATED_TO"

  defp normalize_relationship_type(type) when is_binary(type) do
    type
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9_]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp normalize_relationship_type(_), do: "RELATED_TO"

  defp normalize_strength(nil), do: nil

  defp normalize_strength(strength) when is_integer(strength) do
    strength
    |> max(1)
    |> min(10)
  end

  defp normalize_strength(strength) when is_binary(strength) do
    case Integer.parse(strength) do
      {val, _} -> normalize_strength(val)
      :error -> nil
    end
  end

  defp normalize_strength(_), do: nil

  defp valid_relationship?(%{source: source, target: target, type: type}, entity_names) do
    is_binary(source) and
      is_binary(target) and
      is_binary(type) and
      source != target and
      MapSet.member?(entity_names, source) and
      MapSet.member?(entity_names, target)
  end
end
