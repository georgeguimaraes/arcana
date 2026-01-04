defmodule Mix.Tasks.Arcana.ReembedChunks do
  @moduledoc """
  Re-embeds all chunks with the current embedding configuration.

  Use this after switching embedding models or updating to a new version.

      $ mix arcana.reembed_chunks

  ## Options

    * `--collection` - Only re-embed chunks in the specified collection
    * `--batch-size` - Number of chunks to process at once (default: 50)
    * `--concurrency N` - Number of parallel embedding requests (default: 5)
    * `--skip N` - Skip first N chunks (for resuming interrupted runs)
    * `--quiet` - Suppress progress output

  ## Examples

      # Default usage (all collections)
      mix arcana.reembed_chunks

      # Re-embed only a specific collection
      mix arcana.reembed_chunks --collection my-docs

      # With larger batch size and higher concurrency
      mix arcana.reembed_chunks --batch-size 100 --concurrency 10

      # Resume from chunk 500
      mix arcana.reembed_chunks --skip 500

      # Quiet mode (no progress bar)
      mix arcana.reembed_chunks --quiet

  """

  use Mix.Task

  @shortdoc "Re-embeds all chunks with current embedding config"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          batch_size: :integer,
          quiet: :boolean,
          collection: :string,
          concurrency: :integer,
          skip: :integer
        ]
      )

    batch_size = Keyword.get(opts, :batch_size, 50)
    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    concurrency = Keyword.get(opts, :concurrency, 5)
    skip = Keyword.get(opts, :skip, 0)

    # Start the host application (which will start the repo)
    Mix.Task.run("app.start")

    repo = Application.get_env(:arcana, :repo)

    unless repo do
      Mix.raise("No repo configured. Set config :arcana, repo: YourApp.Repo")
    end

    # Show current embedding info
    info = Arcana.Maintenance.embedding_info()
    Mix.shell().info("Embedding config: #{format_info(info)}")

    # Build progress callback
    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        build_progress_fn()
      end

    scope = if collection, do: "collection '#{collection}'", else: "all collections"
    skip_msg = if skip > 0, do: " (skipping first #{skip})", else: ""
    Mix.shell().info("Re-embedding chunks in #{scope}#{skip_msg}...")

    reembed_opts = [
      batch_size: batch_size,
      progress: progress_fn,
      concurrency: concurrency,
      skip: skip
    ]

    reembed_opts =
      if collection, do: Keyword.put(reembed_opts, :collection, collection), else: reembed_opts

    {:ok, %{rechunked_documents: docs, total_chunks: total, skipped: skipped}} =
      Arcana.Maintenance.reembed(repo, reembed_opts)

    unless quiet, do: IO.puts("")

    if docs > 0 do
      Mix.shell().info("Rechunked #{docs} documents.")
    end

    skip_info = if skipped > 0, do: " (#{skipped} skipped)", else: ""
    Mix.shell().info("Done! #{total} chunks total#{skip_info}.")
  end

  defp format_info(%{type: :local, model: model, dimensions: dims}) do
    "local (#{model}, #{dims} dims)"
  end

  defp format_info(%{type: :openai, model: model, dimensions: dims}) do
    "openai (#{model}, #{dims} dims)"
  end

  defp format_info(%{type: :custom, dimensions: dims}) do
    "custom (#{dims} dims)"
  end

  defp format_info(%{type: type, dimensions: dims}) do
    "#{type} (#{dims} dims)"
  end

  defp build_progress_fn do
    # Simple progress indicator
    fn current, total ->
      percent = round(current / total * 100)
      bar_width = 40
      filled = round(percent / 100 * bar_width)
      empty = bar_width - filled

      bar = String.duplicate("=", filled) <> String.duplicate(" ", empty)
      IO.write("\r[#{bar}] #{percent}% (#{current}/#{total})")
    end
  end
end
