if Code.ensure_loaded?(ExLeiden) do
  defmodule Arcana.Graph.CommunityDetector.Leiden do
    @moduledoc """
    Leiden algorithm implementation for community detection.

    Uses the ExLeiden library to detect communities in entity graphs.
    The Leiden algorithm is a refinement of the Louvain algorithm that
    guarantees well-connected communities.

    ## Usage

        detector = {Arcana.Graph.CommunityDetector.Leiden, resolution: 1.0}
        {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

    ## Options

      - `:resolution` - Controls community granularity (default: 1.0)
        Higher values produce smaller communities
      - `:max_level` - Maximum hierarchy levels (default: 3)
      - `:theta` - Convergence threshold (default: 0.01)
        Higher values converge faster but may be less precise

    """

    @behaviour Arcana.Graph.CommunityDetector

    @impl true
    def detect([], _relationships, _opts), do: {:ok, []}

    require Logger

    def detect(entities, relationships, opts) do
      resolution = Keyword.get(opts, :resolution, 1.0)
      max_level = Keyword.get(opts, :max_level, 3)
      theta = Keyword.get(opts, :theta, 0.01)

      entity_ids = Enum.map(entities, & &1.id)
      edges = to_edges(entity_ids, relationships)

      Logger.info(
        "[Leiden] Starting: #{length(entity_ids)} entities, #{length(edges)} edges, " <>
          "resolution=#{resolution}, max_level=#{max_level}, theta=#{theta}"
      )

      :telemetry.span(
        [:arcana, :graph, :community_detection],
        %{entity_count: length(entities)},
        fn ->
          start_time = System.monotonic_time(:millisecond)

          leiden_opts = [resolution: resolution, max_level: max_level, theta: theta]

          result =
            case ExLeiden.call({entity_ids, edges}, leiden_opts) do
              {:ok, %{source: source, result: level_results}} ->
                elapsed = System.monotonic_time(:millisecond) - start_time

                Logger.info(
                  "[Leiden] Completed in #{elapsed}ms: #{map_size(level_results)} levels"
                )

                communities = format_communities(level_results, source)
                {:ok, communities}

              {:error, reason} ->
                elapsed = System.monotonic_time(:millisecond) - start_time
                Logger.error("[Leiden] Failed after #{elapsed}ms: #{inspect(reason)}")
                {:error, reason}
            end

          metadata =
            case result do
              {:ok, communities} -> %{community_count: length(communities)}
              {:error, _} -> %{community_count: 0}
            end

          {result, metadata}
        end
      )
    end

    @doc """
    Converts relationships to weighted edge tuples for ExLeiden.

    Filters out relationships that reference unknown entities and
    defaults missing strength values to 1.

    ## Examples

        iex> to_edges(["a", "b"], [%{source_id: "a", target_id: "b", strength: 5}])
        [{"a", "b", 5}]

    """
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

    defp format_communities(level_results, source) do
      # level_results is a map of level => {communities, _edges}
      # Each community has :id and :children (indices into source.degree_sequence)
      # degree_sequence contains the original vertex IDs
      vertices = source.degree_sequence

      # Also handle orphan communities (disconnected nodes)
      orphans = source.orphan_communities || []

      communities =
        level_results
        |> Enum.flat_map(fn {level, {communities, _edges}} ->
          Enum.map(communities, fn community ->
            entity_ids =
              community.children
              |> Enum.map(&Enum.at(vertices, &1))
              |> Enum.reject(&is_nil/1)

            %{
              level: level - 1,
              entity_ids: entity_ids
            }
          end)
        end)

      # Add orphan communities at level 0
      orphan_communities =
        Enum.map(orphans, fn orphan_id ->
          %{level: 0, entity_ids: [orphan_id]}
        end)

      (communities ++ orphan_communities)
      |> Enum.sort_by(& &1.level)
    end
  end
end
