if Code.ensure_loaded?(ExLeiden) do
  defmodule Arcana.Graph.CommunityDetector do
    @moduledoc """
    Detects communities in the entity graph using the Leiden algorithm.

    Uses ExLeiden (when available) to partition entities into hierarchical
    communities based on their relationship strengths. The Leiden algorithm
    improves on Louvain by guaranteeing well-connected communities.

    ## Options

      * `:resolution` - Controls community granularity (default: 1.0)
        - Lower values = fewer, larger communities
        - Higher values = more, smaller communities

      * `:max_level` - Maximum hierarchical levels (default: 5)

      * `:quality_function` - `:modularity` (default) or `:cpm`

    ## Example

        entities = [%{id: "a", name: "A"}, %{id: "b", name: "B"}]
        relationships = [%{source_id: "a", target_id: "b", strength: 10}]

        {:ok, communities} = CommunityDetector.detect(entities, relationships)
        # => [%{level: 0, entity_ids: ["a", "b"]}]

    """

    @type entity :: %{id: String.t(), name: String.t()}
    @type relationship :: %{source_id: String.t(), target_id: String.t(), strength: integer() | nil}
    @type community :: %{level: non_neg_integer(), entity_ids: [String.t()]}

    @default_opts [
      resolution: 1.0,
      max_level: 5,
      quality_function: :modularity
    ]

    @doc """
    Detects communities in the entity graph.

    Takes a list of entities and relationships, converts them to a weighted
    edge graph, and runs the Leiden algorithm to find community structure.

    Returns a list of community maps, each with:
      * `:level` - Hierarchy level (0 = finest, higher = coarser)
      * `:entity_ids` - List of entity IDs in this community

    ## Options

      * `:resolution` - Community granularity (default: 1.0)
      * `:max_level` - Maximum hierarchy levels (default: 5)
      * `:quality_function` - `:modularity` or `:cpm` (default: `:modularity`)

    """
    @spec detect([entity()], [relationship()], keyword()) :: {:ok, [community()]}
    def detect(entities, relationships, opts \\ [])
    def detect([], _relationships, _opts), do: {:ok, []}

    def detect(entities, relationships, opts) do
      opts = Keyword.merge(@default_opts, opts)
      entity_ids = Enum.map(entities, & &1.id)
      edges = to_edges(entity_ids, relationships)

      :telemetry.span([:arcana, :graph, :community_detection], %{entity_count: length(entities)}, fn ->
        result = run_leiden(entity_ids, edges, opts)
        {result, %{community_count: length(elem(result, 1))}}
      end)
    end

    @doc """
    Converts relationships to weighted edge tuples for ExLeiden.

    Filters out relationships that reference unknown entities and
    defaults strength to 1 when not specified.
    """
    @spec to_edges([String.t()], [relationship()]) :: [{String.t(), String.t(), number()}]
    def to_edges(entity_ids, relationships) do
      entity_set = MapSet.new(entity_ids)

      relationships
      |> Enum.filter(fn rel ->
        MapSet.member?(entity_set, rel.source_id) and
          MapSet.member?(entity_set, rel.target_id)
      end)
      |> Enum.map(fn rel ->
        weight = Map.get(rel, :strength, 1) || 1
        {rel.source_id, rel.target_id, weight}
      end)
    end

    defp run_leiden(entity_ids, [], _opts) do
      # No edges = each entity is its own community
      communities =
        entity_ids
        |> Enum.with_index()
        |> Enum.map(fn {id, _idx} ->
          %{level: 0, entity_ids: [id]}
        end)

      {:ok, communities}
    end

    defp run_leiden(entity_ids, edges, opts) do
      leiden_opts = [
        resolution: opts[:resolution],
        max_level: opts[:max_level],
        quality_function: opts[:quality_function]
      ]

      case ExLeiden.call(edges, leiden_opts) do
        {:ok, %{result: result}} ->
          communities = extract_communities(result, entity_ids)
          {:ok, communities}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # ExLeiden returns %{level => {communities_list, bridges_list}, ...}
    defp extract_communities(result, entity_ids) when is_map(result) do
      entity_id_list = Enum.to_list(entity_ids)

      if map_size(result) == 0 do
        Enum.map(entity_id_list, &%{level: 0, entity_ids: [&1]})
      else
        result
        |> Enum.sort_by(fn {level, _} -> level end)
        |> Enum.flat_map(&parse_level_communities(&1, entity_id_list))
      end
    end

    # Fallback for tuple format
    defp extract_communities({_level_count, {communities_list, _bridges}}, entity_ids) do
      entity_id_list = Enum.to_list(entity_ids)

      communities_list
      |> Enum.map(&parse_community(&1, entity_id_list, 0))
      |> Enum.reject(&(&1.entity_ids == []))
    end

    # Fallback for list format
    defp extract_communities(result, entity_ids) when is_list(result) do
      entity_id_list = Enum.to_list(entity_ids)

      result
      |> Enum.with_index()
      |> Enum.flat_map(fn {level_communities, level} ->
        level_communities
        |> List.wrap()
        |> Enum.map(&parse_community(&1, entity_id_list, level))
        |> Enum.reject(&(&1.entity_ids == []))
      end)
    end

    defp parse_level_communities({level, {communities_list, _bridges}}, entity_id_list) do
      communities_list
      |> Enum.map(&parse_community(&1, entity_id_list, level - 1))
      |> Enum.reject(&(&1.entity_ids == []))
    end

    defp parse_community(%{id: _id, children: children}, entity_id_list, level) do
      ids = resolve_indices(children, entity_id_list)
      %{level: level, entity_ids: ids}
    end

    defp parse_community(community, entity_id_list, level) when is_list(community) do
      ids = resolve_indices(community, entity_id_list)
      %{level: level, entity_ids: ids}
    end

    defp parse_community(%{children: children}, entity_id_list, level) do
      ids = resolve_indices(children, entity_id_list)
      %{level: level, entity_ids: ids}
    end

    defp resolve_indices(indices, entity_id_list) do
      indices
      |> List.wrap()
      |> Enum.map(&index_to_id(&1, entity_id_list))
      |> Enum.reject(&is_nil/1)
    end

    defp index_to_id(idx, entity_id_list) when is_integer(idx) do
      Enum.at(entity_id_list, idx)
    end

    defp index_to_id(id, _entity_id_list), do: id
  end
end
