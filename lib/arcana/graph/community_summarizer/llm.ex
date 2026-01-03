defmodule Arcana.Graph.CommunitySummarizer.LLM do
  @moduledoc """
  LLM-based community summarizer.

  Uses a language model to generate natural language summaries of
  knowledge graph communities based on their entities and relationships.

  ## Configuration

      config :arcana, :graph,
        community_summarizer: {Arcana.Graph.CommunitySummarizer.LLM, llm: &MyApp.llm/3}

  ## Options

    - `:llm` - Required. A function `(prompt, context, opts) -> {:ok, response}`

  """

  @behaviour Arcana.Graph.CommunitySummarizer

  @impl true
  def summarize(entities, relationships, opts) do
    llm = Keyword.fetch!(opts, :llm)
    prompt = build_prompt(entities, relationships)

    :telemetry.span(
      [:arcana, :graph, :community_summary],
      %{entity_count: length(entities)},
      fn ->
        result = llm.(prompt, [], system_prompt: system_prompt())

        metadata =
          case result do
            {:ok, summary} -> %{summary_length: String.length(summary)}
            {:error, _} -> %{summary_length: 0}
          end

        {result, metadata}
      end
    )
  end

  @doc """
  Builds the prompt for community summarization.
  """
  def build_prompt(entities, relationships) do
    entity_section = format_entities(entities)
    relationship_section = format_relationships(relationships)

    """
    Generate a summary of the following knowledge graph community.

    # ENTITIES
    #{entity_section}

    # RELATIONSHIPS
    #{relationship_section}

    # TASK
    Write a 2-3 sentence summary that:
    1. Identifies the community's central theme or domain
    2. Names the most important entities (those with the most connections)
    3. Describes how the key entities relate to each other

    Output only the summary paragraph, nothing else.
    """
  end

  defp system_prompt do
    """
    You are a knowledge graph analyst performing information discovery.
    Your task is to write concise summaries of entity communities that will
    be used as context for answering user queries.

    Guidelines:
    - Only include information that is explicitly present in the provided data
    - Prioritize entities that have more relationships (they are more central)
    - Focus on factual descriptions, not speculation or interpretation
    - Write in a neutral, informative tone suitable for search context
    """
  end

  defp format_entities([]), do: "No entities in this community."

  defp format_entities(entities) do
    Enum.map_join(entities, "\n", fn entity ->
      desc =
        case Map.get(entity, :description) do
          nil -> ""
          "" -> ""
          d -> " - #{d}"
        end

      "- #{entity.name} (#{entity.type})#{desc}"
    end)
  end

  defp format_relationships([]), do: "No relationships."

  defp format_relationships(relationships) do
    Enum.map_join(relationships, "\n", fn rel ->
      desc =
        case Map.get(rel, :description) do
          nil -> ""
          "" -> ""
          d -> ": #{d}"
        end

      "- #{rel.source} --[#{rel.type}]--> #{rel.target}#{desc}"
    end)
  end
end
