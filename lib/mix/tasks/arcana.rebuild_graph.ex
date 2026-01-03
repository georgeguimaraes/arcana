defmodule Mix.Tasks.Arcana.RebuildGraph do
  @moduledoc """
  Rebuilds the knowledge graph for all documents.

  Use this after changing graph extractor configuration or enabling
  relationship extraction.

      $ mix arcana.rebuild_graph

  ## Options

    * `--collection` - Only rebuild graph for the specified collection
    * `--quiet` - Suppress progress output

  ## Examples

      # Default usage (all collections)
      mix arcana.rebuild_graph

      # Rebuild only a specific collection
      mix arcana.rebuild_graph --collection my-docs

      # Quiet mode (no progress bar)
      mix arcana.rebuild_graph --quiet

  """

  use Mix.Task

  @shortdoc "Rebuilds the knowledge graph from documents"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [quiet: :boolean, collection: :string]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)

    # Start the host application (which will start the repo)
    Mix.Task.run("app.start")

    repo = Application.get_env(:arcana, :repo)

    unless repo do
      Mix.raise("No repo configured. Set config :arcana, repo: YourApp.Repo")
    end

    # Show current graph info
    info = Arcana.Maintenance.graph_info()
    Mix.shell().info("Graph config: #{format_info(info)}")

    unless info.enabled do
      Mix.shell().info("Warning: GraphRAG is disabled. Enable it in config to use graph features.")
    end

    # Build progress callback
    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        build_progress_fn()
      end

    scope = if collection, do: "collection '#{collection}'", else: "all collections"
    Mix.shell().info("Rebuilding graph for #{scope}...")

    rebuild_opts = [progress: progress_fn]
    rebuild_opts = if collection, do: Keyword.put(rebuild_opts, :collection, collection), else: rebuild_opts

    {:ok, %{collections: collections, entities: entities, relationships: relationships}} =
      Arcana.Maintenance.rebuild_graph(repo, rebuild_opts)

    unless quiet, do: IO.puts("")

    Mix.shell().info("Done! Processed #{collections} collection(s): #{entities} entities, #{relationships} relationships.")
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
    fn current, total ->
      percent = round(current / total * 100)
      bar_width = 40
      filled = round(percent / 100 * bar_width)
      empty = bar_width - filled

      bar = String.duplicate("=", filled) <> String.duplicate(" ", empty)
      IO.write("\r[#{bar}] #{percent}% (#{current}/#{total} collections)")
    end
  end
end
