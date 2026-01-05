if Code.ensure_loaded?(Leidenfold) do
  defmodule Arcana.Graph.CommunityDetector.Leiden do
    @moduledoc """
    Leiden algorithm implementation for community detection.

    Uses the Leidenfold library (Rust NIF) to detect communities in entity graphs.
    The Leiden algorithm is a refinement of the Louvain algorithm that
    guarantees well-connected communities.

    ## Installation

    Add `leidenfold` to your dependencies in `mix.exs`:

        defp deps do
          [
            {:arcana, "~> 1.2"},
            {:leidenfold, "~> 0.2"}
          ]
        end

    Precompiled binaries are available for macOS (Apple Silicon) and Linux (x86_64, ARM64).

    ## Usage

        detector = {Arcana.Graph.CommunityDetector.Leiden, resolution: 1.0}
        {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

    ## Options

      - `:resolution` - Controls community granularity (default: 1.0)
        Higher values produce smaller communities
      - `:objective` - Quality function to optimize (default: :cpm)
        Options: :cpm, :modularity, :rber, :rbc, :significance, :surprise
      - `:iterations` - Number of optimization iterations (default: 2)
      - `:seed` - Random seed for reproducibility (default: 0 = random)
      - `:min_size` - Minimum community size to include (default: 1)
        Set to 2 to exclude singleton communities
      - `:max_level` - Maximum hierarchy levels to generate (default: 1)
        Higher levels contain coarser communities built by aggregating lower levels

    """

    @behaviour Arcana.Graph.CommunityDetector

    require Logger

    @impl true
    def detect([], _relationships, _opts), do: {:ok, []}

    def detect(entities, relationships, opts) do
      resolution = Keyword.get(opts, :resolution, 1.0)
      objective = Keyword.get(opts, :objective, :cpm)
      iterations = Keyword.get(opts, :iterations, 2)
      seed = Keyword.get(opts, :seed, 0)
      min_size = Keyword.get(opts, :min_size, 1)
      max_level = Keyword.get(opts, :max_level, 1)

      # Build index mappings
      entity_ids = Enum.map(entities, & &1.id)
      id_to_index = entity_ids |> Enum.with_index() |> Map.new()
      index_to_id = entity_ids |> Enum.with_index() |> Map.new(fn {id, idx} -> {idx, id} end)

      # Convert to weighted edge tuples with integer indices
      edges = to_weighted_edges(id_to_index, relationships)

      Logger.info(
        "[Leiden] Starting: #{length(entity_ids)} entities, #{length(edges)} edges, " <>
          "resolution=#{resolution}, objective=#{objective}, min_size=#{min_size}, max_level=#{max_level}"
      )

      :telemetry.span(
        [:arcana, :graph, :community_detection],
        %{entity_count: length(entities), detector: :leiden},
        fn ->
          start_time = System.monotonic_time(:millisecond)

          leiden_opts = [
            n_nodes: length(entity_ids),
            objective: objective,
            resolution: resolution,
            iterations: iterations,
            seed: seed
          ]

          result =
            case detect_hierarchical(edges, index_to_id, leiden_opts, max_level, min_size) do
              {:ok, communities} ->
                elapsed = System.monotonic_time(:millisecond) - start_time
                by_level = Enum.group_by(communities, & &1.level)

                level_summary =
                  by_level
                  |> Enum.sort_by(&elem(&1, 0))
                  |> Enum.map(fn {lvl, comms} -> "L#{lvl}=#{length(comms)}" end)
                  |> Enum.join(", ")

                Logger.info("[Leiden] Completed in #{elapsed}ms: #{level_summary}")
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

    # Detect communities hierarchically by aggregating and re-running Leiden
    defp detect_hierarchical(edges, index_to_id, leiden_opts, max_level, min_size) do
      n_nodes = Keyword.fetch!(leiden_opts, :n_nodes)

      case Leidenfold.detect_from_weighted_edges(edges, leiden_opts) do
        {:ok, %{membership: membership}} ->
          # Build level 0 communities
          level_0 = format_communities(membership, index_to_id, 0, min_size)

          if max_level <= 1 or length(level_0) <= 1 do
            {:ok, level_0}
          else
            # Build higher levels by aggregation
            higher_levels = build_higher_levels(membership, edges, n_nodes, index_to_id, leiden_opts, 1, max_level, min_size)
            {:ok, level_0 ++ higher_levels}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Build higher hierarchy levels by aggregating communities
    defp build_higher_levels(_membership, _edges, _n_nodes, _index_to_id, _opts, current_level, max_level, _min_size)
         when current_level >= max_level do
      []
    end

    defp build_higher_levels(membership, edges, n_nodes, index_to_id, leiden_opts, current_level, max_level, min_size) do
      # Aggregate: create graph where nodes are communities from previous level
      {agg_edges, n_communities, community_to_entities} =
        aggregate_graph(membership, edges, n_nodes)

      # Stop if we can't aggregate further
      if n_communities <= 1 or length(agg_edges) == 0 do
        []
      else
        agg_opts = Keyword.put(leiden_opts, :n_nodes, n_communities)

        case Leidenfold.detect_from_weighted_edges(agg_edges, agg_opts) do
          {:ok, %{membership: agg_membership}} ->
            # Map aggregated communities back to entity IDs
            communities = format_aggregated_communities(agg_membership, community_to_entities, index_to_id, current_level, min_size)

            if length(communities) <= 1 do
              communities
            else
              # Recurse for even higher levels
              communities ++ build_higher_levels(agg_membership, agg_edges, n_communities, index_to_id, leiden_opts, current_level + 1, max_level, min_size)
            end

          {:error, _} ->
            []
        end
      end
    end

    # Aggregate the graph: communities become nodes, edges weighted by inter-community connections
    defp aggregate_graph(membership, edges, n_nodes) do
      # Build mapping from node to community
      node_to_community = membership |> Enum.with_index() |> Map.new(fn {comm, idx} -> {idx, comm} end)

      # Count unique communities
      n_communities = membership |> Enum.max(fn -> -1 end) |> Kernel.+(1)

      # Build community_to_entities mapping (list of node indices per community)
      community_to_entities =
        0..(n_nodes - 1)
        |> Enum.group_by(&Map.get(node_to_community, &1, 0))

      # Aggregate edges between communities
      edge_weights =
        edges
        |> Enum.reduce(%{}, fn {src, tgt, weight}, acc ->
          src_comm = Map.get(node_to_community, src, 0)
          tgt_comm = Map.get(node_to_community, tgt, 0)

          # Skip self-loops (edges within same community)
          if src_comm != tgt_comm do
            # Normalize edge to smaller community first for consistency
            key = if src_comm < tgt_comm, do: {src_comm, tgt_comm}, else: {tgt_comm, src_comm}
            Map.update(acc, key, weight, &(&1 + weight))
          else
            acc
          end
        end)

      # Convert to edge list
      agg_edges =
        edge_weights
        |> Enum.map(fn {{src, tgt}, weight} -> {src, tgt, weight} end)

      {agg_edges, n_communities, community_to_entities}
    end

    # Format aggregated communities back to entity IDs
    defp format_aggregated_communities(agg_membership, community_to_entities, index_to_id, level, min_size) do
      # Group lower-level communities by their higher-level community assignment
      agg_membership
      |> Enum.with_index()
      |> Enum.group_by(fn {higher_comm, _lower_comm} -> higher_comm end, fn {_, lower_comm} -> lower_comm end)
      |> Enum.map(fn {_higher_comm, lower_comms} ->
        # Flatten all entity indices from the grouped lower-level communities
        entity_indices = Enum.flat_map(lower_comms, &Map.get(community_to_entities, &1, []))
        # Convert indices back to entity IDs
        entity_ids = Enum.map(entity_indices, &Map.fetch!(index_to_id, &1))
        %{level: level, entity_ids: entity_ids}
      end)
      |> Enum.filter(fn %{entity_ids: ids} -> length(ids) >= min_size end)
    end

    # Convert relationships to weighted edge tuples {source_idx, target_idx, weight}
    defp to_weighted_edges(id_to_index, relationships) do
      relationships
      |> Enum.filter(fn rel ->
        Map.has_key?(id_to_index, rel.source_id) and
          Map.has_key?(id_to_index, rel.target_id)
      end)
      |> Enum.map(fn rel ->
        source_idx = Map.fetch!(id_to_index, rel.source_id)
        target_idx = Map.fetch!(id_to_index, rel.target_id)
        weight = (Map.get(rel, :strength, 1) || 1) / 1
        {source_idx, target_idx, weight}
      end)
    end

    # Convert membership list to community maps
    # membership[node_idx] = community_id
    defp format_communities(membership, index_to_id, level, min_size) do
      membership
      |> Enum.with_index()
      |> Enum.group_by(fn {community_id, _node_idx} -> community_id end, fn {_community_id, node_idx} ->
        Map.fetch!(index_to_id, node_idx)
      end)
      |> Enum.map(fn {_community_id, entity_ids} ->
        %{level: level, entity_ids: entity_ids}
      end)
      |> Enum.filter(fn %{entity_ids: ids} -> length(ids) >= min_size end)
    end
  end
end
