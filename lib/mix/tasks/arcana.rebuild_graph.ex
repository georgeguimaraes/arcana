defmodule Mix.Tasks.Arcana.RebuildGraph do
  @moduledoc """
  Rebuilds the knowledge graph for all documents.

  Use this after changing graph extractor configuration or enabling
  relationship extraction.

      $ mix arcana.rebuild_graph

  ## Options

    * `--collection` - Only rebuild graph for the specified collection
    * `--quiet` - Suppress progress output
    * `--resume` - Skip chunks that already have entity mentions (for resuming interrupted builds)
    * `--concurrency N` - Number of parallel LLM requests (default: 3)

  ## Examples

      # Default usage (all collections)
      mix arcana.rebuild_graph

      # Rebuild only a specific collection
      mix arcana.rebuild_graph --collection my-docs

      # Resume an interrupted build
      mix arcana.rebuild_graph --resume

      # Control parallelism (default is 3)
      mix arcana.rebuild_graph --concurrency 5

      # Quiet mode (no progress bar)
      mix arcana.rebuild_graph --quiet

  """

  use Mix.Task

  @shortdoc "Rebuilds the knowledge graph from documents"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [quiet: :boolean, collection: :string, resume: :boolean, concurrency: :integer]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    resume = Keyword.get(opts, :resume, false)
    concurrency = Keyword.get(opts, :concurrency, 3)

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
      Mix.shell().info(
        "Warning: GraphRAG is disabled. Enable it in config to use graph features."
      )
    end

    # Build progress callback
    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        build_progress_fn()
      end

    scope = if collection, do: "collection '#{collection}'", else: "all collections"
    mode = if resume, do: " (resuming)", else: ""
    Mix.shell().info("Rebuilding graph for #{scope}#{mode}...\n")

    rebuild_opts = [progress: progress_fn, concurrency: concurrency]

    rebuild_opts =
      if collection, do: Keyword.put(rebuild_opts, :collection, collection), else: rebuild_opts

    rebuild_opts = if resume, do: Keyword.put(rebuild_opts, :resume, true), else: rebuild_opts

    {:ok,
     %{
       collections: collections,
       entities: entities,
       relationships: relationships,
       skipped: skipped
     }} =
      Arcana.Maintenance.rebuild_graph(repo, rebuild_opts)

    skip_msg = if skipped > 0, do: " (skipped #{skipped} already processed)", else: ""

    Mix.shell().info(
      "\nDone! Processed #{collections} collection(s): #{entities} entities, #{relationships} relationships#{skip_msg}."
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
      # Called when starting to process a collection's chunks
      :chunk_start, %{collection: name, chunk_count: count} = info ->
        skip_info = Map.get(info, :skip_info, "")
        IO.puts("  Processing '#{name}' (#{count} chunks#{skip_info})...")

      # Called after each chunk is processed
      :chunk_progress, %{collection: _name, current: current, total: total} ->
        percent = round(current / total * 100)
        IO.write("\r    Chunk #{current}/#{total} (#{percent}%)")

        if current == total do
          IO.puts(" - done")
        end

      # Called after collection completes (if detailed mode)
      :collection_complete, %{index: idx, total: total, collection: name, result: result} ->
        skip_msg = if result.skipped > 0, do: ", #{result.skipped} skipped", else: ""

        IO.puts(
          "  [#{idx}/#{total}] '#{name}': #{result.entities} entities, #{result.relationships} relationships#{skip_msg}"
        )

      # Legacy: simple index/total progress
      current, total when is_integer(current) and is_integer(total) ->
        :ok
    end
  end
end
