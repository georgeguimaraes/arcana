defmodule Mix.Tasks.Arcana.Graph.SummarizeCommunities do
  @moduledoc """
  Generates LLM summaries for knowledge graph communities.

  Use this after detecting communities to generate natural language
  summaries that provide high-level context for global queries.

      $ mix arcana.graph.summarize_communities

  ## Options

    * `--collection` - Only summarize communities for the specified collection
    * `--force` - Regenerate all summaries, not just dirty ones
    * `--concurrency` - Number of parallel summarization tasks (default: 1)
    * `--levels` - Hierarchy levels to summarize: `all` or a comma-separated
      list (default: the levels `ask` reads, `community_summary_level`)
    * `--quiet` - Suppress progress output

  ## Examples

      # Default usage (summarize dirty communities)
      mix arcana.graph.summarize_communities

      # Summarize a specific collection
      mix arcana.graph.summarize_communities --collection my-docs

      # Force regenerate all summaries
      mix arcana.graph.summarize_communities --force

      # Summarize every hierarchy level, not just the readable ones
      mix arcana.graph.summarize_communities --levels all

      # Parallel summarization (4 concurrent tasks)
      mix arcana.graph.summarize_communities --concurrency 4

      # Quiet mode
      mix arcana.graph.summarize_communities --quiet

  ## Requirements

  This task requires an LLM to be configured. Supported formats:
    config :arcana, :llm, "openai:gpt-4o-mini"
    config :arcana, :llm, {"openai:gpt-4o-mini", api_key: "..."}
    config :arcana, :llm, fn prompt, context, opts ->
      {:ok, MyApp.LLM.complete(prompt)}
    end

  """

  use Mix.Task

  @shortdoc "Generates summaries for knowledge graph communities"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          quiet: :boolean,
          collection: :string,
          force: :boolean,
          concurrency: :integer,
          levels: :string
        ],
        aliases: [f: :force, c: :concurrency]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    force = Keyword.get(opts, :force, false)
    concurrency = Keyword.get(opts, :concurrency, 1)
    levels = parse_levels(Keyword.get(opts, :levels))

    # Start the host application (which will start the repo)
    Mix.Task.run("app.start")

    repo = Arcana.MixHelpers.repo!()

    # Check LLM is configured
    unless Application.get_env(:arcana, :llm) do
      Mix.raise("""
      No LLM configured for community summarization.
      Add to your config:

          # String format (simplest)
          config :arcana, :llm, "openai:gpt-4o-mini"

          # Or tuple with options
          config :arcana, :llm, {"openai:gpt-4o-mini", api_key: "..."}

          # Or function
          config :arcana, :llm, fn prompt, context, opts ->
            {:ok, MyApp.LLM.complete(prompt)}
          end
      """)
    end

    # Show current config
    info = Arcana.Maintenance.graph_info()
    Mix.shell().info("Graph config: #{format_info(info)}")

    Mix.shell().info(
      "Summarization: force=#{force}, concurrency=#{concurrency}, levels=#{format_levels(levels)}"
    )

    # Build progress callback
    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        build_progress_fn()
      end

    scope = if collection, do: "collection '#{collection}'", else: "all collections"
    Mix.shell().info("Summarizing communities for #{scope}...\n")

    summarize_opts = [
      progress: progress_fn,
      force: force,
      concurrency: concurrency,
      levels: levels
    ]

    summarize_opts =
      if collection,
        do: Keyword.put(summarize_opts, :collection, collection),
        else: summarize_opts

    case Arcana.Maintenance.summarize_communities(repo, summarize_opts) do
      {:ok, %{communities: communities, summaries: summaries}} ->
        Mix.shell().info(
          "\nDone! Processed #{communities} communities, generated #{summaries} summaries."
        )

      {:error, {:unknown_collection, name}} ->
        Mix.raise("Collection #{inspect(name)} does not exist")
    end
  end

  defp parse_levels(nil), do: Arcana.Graph.summary_levels()
  defp parse_levels("all"), do: :all

  defp parse_levels(levels) do
    case String.split(levels, ",", trim: true) do
      [] ->
        Mix.raise(
          ~s(--levels needs at least one level, e.g. --levels 0, --levels 0,1 or --levels all)
        )

      values ->
        Enum.map(values, &parse_level!/1)
    end
  end

  # String.to_integer/1 would raise a bare ArgumentError with a stack trace
  # that never mentions the flag the operator actually got wrong.
  defp parse_level!(value) do
    case value |> String.trim() |> Integer.parse() do
      {level, ""} when level >= 0 ->
        level

      _ ->
        Mix.raise(
          ~s(--levels expects non-negative integers or "all", got: #{inspect(String.trim(value))})
        )
    end
  end

  defp format_levels(:all), do: "all"
  defp format_levels(levels), do: Enum.join(levels, ",")

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
          "  [#{idx}/#{total}] '#{name}': #{result.summaries}/#{result.communities} summaries generated"
        )

      # Legacy: simple index/total progress
      current, total when is_integer(current) and is_integer(total) ->
        :ok
    end
  end
end
