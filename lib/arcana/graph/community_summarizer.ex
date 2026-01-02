defmodule Arcana.Graph.CommunitySummarizer do
  @moduledoc """
  Generates LLM-based summaries for knowledge graph communities.

  Communities are groups of related entities detected by the Leiden algorithm.
  Summaries provide high-level descriptions used for global search queries
  that need broad context rather than specific document chunks.

  ## Threshold-Based Regeneration

  Summaries are regenerated when:
  - A community is marked as dirty (new entities added)
  - The change_count exceeds a configurable threshold
  - No summary exists yet

  This avoids expensive LLM calls for minor changes while ensuring
  summaries stay current as the graph evolves.

  ## Example

      entities = [%{name: "OpenAI", type: :organization}]
      relationships = [%{source: "Sam Altman", target: "OpenAI", type: "LEADS"}]

      {:ok, summary} = CommunitySummarizer.summarize(entities, relationships, llm)
      # => "This community centers on OpenAI, an AI research organization..."

  """

  @type entity :: %{name: String.t(), type: atom(), description: String.t() | nil}
  @type relationship :: %{
          source: String.t(),
          target: String.t(),
          type: String.t(),
          description: String.t() | nil
        }

  @default_threshold 10

  @doc """
  Generates a summary for a community based on its entities and relationships.

  The LLM receives a structured prompt describing the community's contents
  and generates a concise summary suitable for search result context.

  ## Parameters

    - entities: List of entity maps with `:name`, `:type`, and optional `:description`
    - relationships: List of relationship maps connecting entities
    - llm: An LLM function that takes (prompt, context, opts) and returns {:ok, response}
    - opts: Optional keyword list (currently unused)

  ## Returns

    - `{:ok, summary}` - The generated summary string
    - `{:error, reason}` - If the LLM call fails

  """
  @spec summarize(
          [entity()],
          [relationship()],
          (String.t(), list(), keyword() -> {:ok, String.t()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, term()}
  def summarize(entities, relationships, llm, _opts \\ []) do
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

  Creates a structured prompt that describes the community's entities
  and their relationships for the LLM to summarize.
  """
  @spec build_prompt([entity()], [relationship()]) :: String.t()
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

  @doc """
  Checks if a community needs its summary regenerated.

  ## Regeneration Triggers

    - `dirty: true` - Community was modified since last summary
    - `change_count >= threshold` - Many changes accumulated
    - `summary: nil` - No summary exists yet

  ## Options

    - `:threshold` - Number of changes before regeneration (default: 10)

  """
  @spec needs_regeneration?(map(), keyword()) :: boolean()
  def needs_regeneration?(community, opts \\ [])

  def needs_regeneration?(community, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    cond do
      Map.get(community, :dirty, false) -> true
      is_nil(Map.get(community, :summary)) -> true
      Map.get(community, :change_count, 0) >= threshold -> true
      true -> false
    end
  end

  @doc """
  Returns a map of fields to reset after regenerating a summary.

  Use with `Ecto.Changeset.change/2` to mark a community as clean:

      community
      |> Community.changeset(CommunitySummarizer.reset_change_tracking())
      |> Repo.update()

  """
  @spec reset_change_tracking() :: %{change_count: 0, dirty: false}
  def reset_change_tracking do
    %{change_count: 0, dirty: false}
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
