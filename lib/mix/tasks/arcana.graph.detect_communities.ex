defmodule Mix.Tasks.Arcana.Graph.DetectCommunities do
  @moduledoc """
  Detects communities in the knowledge graph using the Leiden algorithm.

  Use this after building or rebuilding the knowledge graph to generate
  community clusters for global queries.

      $ mix arcana.graph.detect_communities

  ## Options

    * `--collection` - Only detect communities for the specified collection
    * `--resolution` - Community detection resolution (default: 1.0, higher = smaller communities)
    * `--objective` - Quality function: cpm (default), modularity, rber, rbc, significance, surprise
    * `--iterations` - Number of optimization iterations (default: 2)
    * `--seed` - Random seed for reproducibility (default: 0 = random)
    * `--min-size` - Minimum community size to include (default: 1, set to 2+ to exclude singletons)
    * `--max-level` - Maximum hierarchy levels to generate (default: 1)
    * `--quiet` - Suppress progress output

  ## Examples

      # Default usage
      mix arcana.graph.detect_communities

      # Detect communities for a specific collection
      mix arcana.graph.detect_communities --collection my-docs

      # With custom resolution (higher = more, smaller communities)
      mix arcana.graph.detect_communities --resolution 1.5

      # Using modularity optimization
      mix arcana.graph.detect_communities --objective modularity

      # Exclude small communities (less than 5 members)
      mix arcana.graph.detect_communities --min-size 5

      # Generate hierarchical communities (3 levels)
      mix arcana.graph.detect_communities --max-level 3

      # Quiet mode (no progress output)
      mix arcana.graph.detect_communities --quiet

  ## Requirements

  This task requires the `leidenfold` package. Add it to your dependencies:

      {:leidenfold, "~> 0.2"}

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
          resolution: :float,
          objective: :string,
          iterations: :integer,
          seed: :integer,
          min_size: :integer,
          max_level: :integer
        ],
        aliases: [s: :min_size, l: :max_level]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    resolution = Keyword.get(opts, :resolution, 1.0)
    objective = Keyword.get(opts, :objective, "cpm") |> String.to_atom()
    iterations = Keyword.get(opts, :iterations, 2)
    seed = Keyword.get(opts, :seed, 0)
    min_size = Keyword.get(opts, :min_size, 1)
    max_level = Keyword.get(opts, :max_level, 1)

    # Start the host application (which will start the repo)
    Mix.Task.run("app.start")

    repo = Application.get_env(:arcana, :repo)

    unless repo do
      Mix.raise("No repo configured. Set config :arcana, repo: YourApp.Repo")
    end

    # Check leidenfold is available
    unless Code.ensure_loaded?(Leidenfold) do
      Mix.raise("""
      Community detection requires the leidenfold package.
      Add {:leidenfold, "~> 0.2"} to your dependencies.
      """)
    end

    # Show current graph info
    info = Arcana.Maintenance.graph_info()
    Mix.shell().info("Graph config: #{format_info(info)}")

    Mix.shell().info(
      "Leiden: resolution=#{resolution}, objective=#{objective}, min_size=#{min_size}, max_level=#{max_level}"
    )

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
      resolution: resolution,
      objective: objective,
      iterations: iterations,
      seed: seed,
      min_size: min_size,
      max_level: max_level
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
