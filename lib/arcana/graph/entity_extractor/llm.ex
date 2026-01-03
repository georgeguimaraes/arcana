defmodule Arcana.Graph.EntityExtractor.LLM do
  @moduledoc """
  LLM-based entity extraction implementation.

  Uses structured prompts to identify named entities from text. The LLM
  returns JSON-formatted entities with name, type, and optional description.

  This extractor is useful when you want to use the same LLM for both
  entity and relationship extraction, or when you need domain-specific
  entity recognition.

  ## Usage

      # Configure with an LLM function
      extractor = {Arcana.Graph.EntityExtractor.LLM, llm: my_llm_fn}
      {:ok, entities} = EntityExtractor.extract(extractor, "Sam Altman leads OpenAI")

  ## Configuration

      config :arcana, :graph,
        entity_extractor: {Arcana.Graph.EntityExtractor.LLM, []}

  When using this extractor, the LLM function is passed automatically
  from the graph pipeline.

  ## Options

    - `:llm` - Required. An LLM function `(prompt, context, opts) -> {:ok, response} | {:error, reason}`
    - `:types` - Optional. List of entity types to extract. Defaults to all standard types.

  """

  @behaviour Arcana.Graph.EntityExtractor

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
    types = Keyword.get(opts, :types, @default_types)
    prompt = build_prompt(text, types)

    :telemetry.span([:arcana, :graph, :entity_extraction], %{text: text}, fn ->
      result =
        case Arcana.LLM.complete(llm, prompt, [], system_prompt: system_prompt()) do
          {:ok, response} ->
            parse_and_validate(response, types)

          {:error, reason} ->
            {:error, reason}
        end

      metadata =
        case result do
          {:ok, entities} -> %{entity_count: length(entities)}
          {:error, _} -> %{entity_count: 0}
        end

      {result, metadata}
    end)
  end

  @impl true
  def extract_batch(texts, opts) when is_list(texts) do
    # For LLM extractors, sequential is fine (LLM already has latency)
    results = Enum.map(texts, fn text -> extract(text, opts) end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(results, fn {:ok, entities} -> entities end)}
    else
      {:error, :batch_failed}
    end
  end

  @doc """
  Builds the prompt for entity extraction.
  """
  def build_prompt(text, types) do
    type_list = Enum.map_join(types, ", ", &to_string/1)

    """
    Extract named entities from the following text.

    ## Text to analyze:
    #{text}

    ## Entity types to extract:
    #{type_list}

    ## Instructions:
    1. Identify all significant named entities in the text
    2. Classify each entity into one of the types listed above
    3. Use "other" for entities that don't fit the categories
    4. Include a brief description if the text provides context

    ## Type definitions:
    - person: Individual people, including names with titles (e.g., "Sam Altman", "Dr. Jane Smith", "CEO John Doe")
    - organization: Companies, institutions, governments, teams, groups (e.g., "OpenAI", "FDA", "United Nations", "Engineering Team")
    - location: Geographic places, addresses, regions, facilities (e.g., "San Francisco", "Building 42", "North America", "MIT Campus")
    - event: Named events, conferences, incidents, historical moments (e.g., "World War II", "GPT-4 Launch", "2024 Election", "Annual Summit")
    - concept: Abstract ideas, theories, methodologies, processes (e.g., "Machine Learning", "Agile Development", "Climate Change", "GDPR Compliance")
    - technology: Products, tools, systems, software, hardware (e.g., "GPT-4", "PostgreSQL", "iPhone 15", "Kubernetes")
    - role: Job titles, positions, responsibilities (e.g., "CEO", "Software Engineer", "Board Member", "Project Manager")
    - publication: Papers, books, articles, reports (e.g., "Attention Is All You Need", "The Lean Startup", "Annual Report 2024")
    - media: Movies, songs, artworks, creative works (e.g., "The Matrix", "Bohemian Rhapsody", "Mona Lisa")
    - award: Awards, certifications, honors (e.g., "Nobel Prize", "ISO 9001", "Grammy Award", "Pulitzer Prize")
    - standard: Specifications, protocols, regulations (e.g., "RFC 2616", "WCAG 2.1", "PCI DSS", "HIPAA")
    - language: Programming or natural languages (e.g., "Python", "Mandarin", "SQL", "JavaScript")
    - other: Entities that don't fit above categories but are still significant named items

    ## Output format:
    Return a JSON array of entity objects. Each object should have:
    - "name": The entity name (required)
    - "type": One of the types listed above (required)
    - "description": Brief description from context (optional)

    Return only the JSON array, no other text.
    """
  end

  defp system_prompt do
    """
    You are a named entity recognition assistant. Your task is to extract
    named entities from text and classify them by type. Be precise and
    extract only clearly identifiable entities.
    Always return valid JSON.
    """
  end

  defp parse_and_validate(response, _types) do
    # Strip any markdown code blocks if present
    cleaned =
      response
      |> String.trim()
      |> String.replace(~r/^```json\n?/, "")
      |> String.replace(~r/\n?```$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, entities} when is_list(entities) ->
        validated =
          entities
          |> Enum.map(&normalize_entity/1)
          |> Enum.filter(&valid_entity?(&1, nil))

        {:ok, validated}

      {:ok, _} ->
        {:error, {:json_parse_error, "Expected JSON array"}}

      {:error, error} ->
        {:error, {:json_parse_error, error}}
    end
  end

  defp normalize_entity(entity) when is_map(entity) do
    %{
      name: Map.get(entity, "name"),
      type: normalize_type(Map.get(entity, "type")),
      description: Map.get(entity, "description"),
      span_start: nil,
      span_end: nil,
      score: nil
    }
  end

  defp normalize_type(nil), do: "other"

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.replace(~r/[^a-z_]/, "")
  end

  defp normalize_type(_), do: "other"

  defp valid_entity?(%{name: name, type: type}, _valid_types) do
    is_binary(name) and
      String.trim(name) != "" and
      is_binary(type) and
      String.trim(type) != ""
  end
end
