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

      # Build index mappings
      entity_ids = Enum.map(entities, & &1.id)
      id_to_index = entity_ids |> Enum.with_index() |> Map.new()
      index_to_id = entity_ids |> Enum.with_index() |> Map.new(fn {id, idx} -> {idx, id} end)

      # Convert to weighted edge tuples with integer indices
      edges = to_weighted_edges(id_to_index, relationships)

      Logger.info(
        "[Leiden] Starting: #{length(entity_ids)} entities, #{length(edges)} edges, " <>
          "resolution=#{resolution}, objective=#{objective}"
      )

      :telemetry.span(
        [:arcana, :graph, :community_detection],
        %{entity_count: length(entities), detector: :leiden},
        fn ->
          start_time = System.monotonic_time(:millisecond)

          result =
            case Leidenfold.detect_from_weighted_edges(edges,
                   n_nodes: length(entity_ids),
                   objective: objective,
                   resolution: resolution,
                   iterations: iterations,
                   seed: seed
                 ) do
              {:ok, %{membership: membership, n_communities: n_communities}} ->
                elapsed = System.monotonic_time(:millisecond) - start_time

                Logger.info(
                  "[Leiden] Completed in #{elapsed}ms: #{n_communities} communities"
                )

                communities = format_communities(membership, index_to_id)
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
    defp format_communities(membership, index_to_id) do
      membership
      |> Enum.with_index()
      |> Enum.group_by(fn {community_id, _node_idx} -> community_id end, fn {_community_id, node_idx} ->
        Map.fetch!(index_to_id, node_idx)
      end)
      |> Enum.map(fn {_community_id, entity_ids} ->
        %{level: 0, entity_ids: entity_ids}
      end)
    end
  end
end
