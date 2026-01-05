defmodule Mix.Tasks.Arcana.DetectCommunities do
  @moduledoc """
  Detects communities in the knowledge graph using the Leiden algorithm.

  Use this after building or rebuilding the knowledge graph to generate
  hierarchical community clusters for global queries.

      $ mix arcana.detect_communities

  ## Options

    * `--collection` - Only detect communities for the specified collection
    * `--detector` - Algorithm implementation: "leidenalg" (default, fast) or "leiden" (ex_leiden, slow)
    * `--resolution` - Community detection resolution (default: 1.0, higher = smaller communities)
    * `--max-level` - Maximum hierarchy levels (default: 3, only for ex_leiden)
    * `--theta` - Convergence threshold (default: 0.01, only for ex_leiden)
    * `--quiet` - Suppress progress output

  ## Detectors

    * `leidenalg` - Python leidenalg via uv (recommended, <1 second for 15k entities)
    * `leiden` - ex_leiden Elixir NIF (slow, ~25 minutes for 15k entities)

  ## Examples

      # Default usage with leidenalg (fast)
      mix arcana.detect_communities

      # Use ex_leiden (slow) with hierarchical levels
      mix arcana.detect_communities --detector leiden --max-level 3

      # Detect communities for a specific collection
      mix arcana.detect_communities --collection my-docs

      # With custom resolution (higher = more, smaller communities)
      mix arcana.detect_communities --resolution 1.5

      # Quiet mode (no progress output)
      mix arcana.detect_communities --quiet

  """

  use Mix.Task

  @shortdoc "Detects communities in the knowledge graph"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          quiet: :boolean,
          collection: :string,
          detector: :string,
          resolution: :float,
          max_level: :integer,
          theta: :float
        ]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    detector = Keyword.get(opts, :detector, "leidenalg")
    resolution = Keyword.get(opts, :resolution, 1.0)
    max_level = Keyword.get(opts, :max_level, 3)
    theta = Keyword.get(opts, :theta, 0.01)

    # Start the host application (which will start the repo)
    Mix.Task.run("app.start")

    repo = Application.get_env(:arcana, :repo)

    unless repo do
      Mix.raise("No repo configured. Set config :arcana, repo: YourApp.Repo")
    end

    # Show current graph info
    info = Arcana.Maintenance.graph_info()
    Mix.shell().info("Graph config: #{format_info(info)}")
    Mix.shell().info("Detector: #{detector}, resolution=#{resolution}" <> format_detector_opts(detector, max_level, theta))

    # Build progress callback
    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        build_progress_fn()
      end

    scope = if collection, do: "collection '#{collection}'", else: "all collections"
    Mix.shell().info("Detecting communities for #{scope}...\n")

    detect_opts = [
      progress: progress_fn,
      detector: detector,
      resolution: resolution,
      max_level: max_level,
      theta: theta
    ]

    detect_opts =
      if collection, do: Keyword.put(detect_opts, :collection, collection), else: detect_opts

    {:ok, %{collections: collections, communities: communities}} =
      Arcana.Maintenance.detect_communities(repo, detect_opts)

    Mix.shell().info(
      "\nDone! Processed #{collections} collection(s): #{communities} communities."
    )
  end

  defp format_info(%{enabled: enabled, extractor_name: name, community_levels: levels}) do
    status = if enabled, do: "enabled", else: "disabled"
    "#{status}, extractor: #{name}, community levels: #{levels}"
  end

  defp format_info(%{enabled: enabled, extractor_type: type, community_levels: levels}) do
    status = if enabled, do: "enabled", else: "disabled"
    "#{status}, extractor: #{type}, community levels: #{levels}"
  end

  defp format_detector_opts("leiden", max_level, theta) do
    ", max_level=#{max_level}, theta=#{theta}"
  end

  defp format_detector_opts(_detector, _max_level, _theta), do: ""

  defp build_progress_fn do
    fn
      # Called when starting to process a collection
      :collection_start, %{collection: name} ->
        IO.puts("  Processing '#{name}'...")

      # Called after collection completes
      :collection_complete, %{index: idx, total: total, collection: name, result: result} ->
        IO.puts(
          "  [#{idx}/#{total}] '#{name}': #{result.communities} communities " <>
            "(#{result.entities} entities, #{result.relationships} relationships)"
        )

      # Legacy: simple index/total progress
      current, total when is_integer(current) and is_integer(total) ->
        :ok
    end
  end
end
