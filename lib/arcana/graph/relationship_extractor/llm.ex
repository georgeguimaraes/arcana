defmodule Arcana.Graph.RelationshipExtractor.LLM do
  @moduledoc """
  LLM-based relationship extraction implementation.

  Uses structured prompts to identify semantic relationships between
  previously extracted entities. The LLM returns JSON-formatted
  relationships with type, description, and strength.

  ## Usage

      # Configure with an LLM function
      extractor = {Arcana.Graph.RelationshipExtractor.LLM, llm: my_llm_fn}
      {:ok, relationships} = RelationshipExtractor.extract(extractor, text, entities)

  ## Options

    - `:llm` - Required. An LLM function `(prompt, context, opts) -> {:ok, response} | {:error, reason}`

  """

  @behaviour Arcana.Graph.RelationshipExtractor

  @impl true
  def extract(_text, [], _opts), do: {:ok, []}

  def extract(text, entities, opts) when is_binary(text) and is_list(entities) do
    llm = Keyword.fetch!(opts, :llm)
    prompt = build_prompt(text, entities)
    entity_names = MapSet.new(entities, & &1.name)

    :telemetry.span([:arcana, :graph, :relationship_extraction], %{text: text}, fn ->
      result =
        case Arcana.LLM.complete(llm, prompt, [], system_prompt: system_prompt()) do
          {:ok, response} ->
            parse_and_validate(response, entity_names)

          {:error, reason} ->
            {:error, reason}
        end

      metadata =
        case result do
          {:ok, rels} -> %{relationship_count: length(rels)}
          {:error, _} -> %{relationship_count: 0}
        end

      {result, metadata}
    end)
  end

  @doc """
  Builds the prompt for relationship extraction.

  The prompt includes the source text and a list of entities
  for the LLM to find relationships between.
  """
  def build_prompt(text, entities) do
    entity_list =
      Enum.map_join(entities, "\n", fn %{name: name, type: type} ->
        "- #{name} (#{type})"
      end)

    """
    Analyze the following text and extract relationships between the entities listed below.

    ## Text to analyze:
    #{text}

    ## Entities to find relationships between:
    #{entity_list}

    ## Instructions:
    1. Identify all meaningful relationships between the listed entities
    2. Only include relationships that are explicitly or strongly implied in the text
    3. Use descriptive relationship types in UPPER_SNAKE_CASE (e.g., WORKS_AT, FOUNDED, LEADS, LOCATED_IN)
    4. Rate the strength of each relationship from 1-10 based on how explicit and central it is to the text

    ## Output format:
    Return a JSON array of relationship objects. Each object should have:
    - "source": Name of the source entity (exactly as listed above)
    - "target": Name of the target entity (exactly as listed above)
    - "type": Relationship type in UPPER_SNAKE_CASE
    - "description": Brief description of the relationship (optional)
    - "strength": Integer from 1-10 indicating relationship strength (optional)

    Return only the JSON array, no other text.
    """
  end

  defp system_prompt do
    """
    You are a knowledge graph construction assistant. Your task is to extract
    semantic relationships between entities from text. Be precise and only
    extract relationships that are clearly stated or strongly implied.
    Always return valid JSON.
    """
  end

  defp parse_and_validate(response, entity_names) do
    # Strip any markdown code blocks if present
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, relationships} when is_list(relationships) ->
        validated =
          relationships
          |> Enum.map(&normalize_relationship/1)
          |> Enum.filter(&valid_relationship?(&1, entity_names))

        {:ok, validated}

      {:ok, _} ->
        {:error, {:json_parse_error, "Expected JSON array"}}

      {:error, error} ->
        {:error, {:json_parse_error, error}}
    end
  end

  defp normalize_relationship(rel) when is_map(rel) do
    %{
      source: Map.get(rel, "source"),
      target: Map.get(rel, "target"),
      type: normalize_type(Map.get(rel, "type")),
      description: Map.get(rel, "description"),
      strength: normalize_strength(Map.get(rel, "strength"))
    }
  end

  defp normalize_type(nil), do: nil

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9_]/, "_")
  end

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
