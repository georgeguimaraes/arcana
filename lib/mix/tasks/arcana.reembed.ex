defmodule Mix.Tasks.Arcana.Reembed do
  @moduledoc """
  Re-embeds all documents with the current embedding configuration.

  Use this after switching embedding models or updating to a new version.

      $ mix arcana.reembed

  ## Options

    * `--batch-size` - Number of chunks to process at once (default: 50)
    * `--quiet` - Suppress progress output

  ## Examples

      # Default usage
      mix arcana.reembed

      # With larger batch size
      mix arcana.reembed --batch-size 100

      # Quiet mode (no progress bar)
      mix arcana.reembed --quiet

  """

  use Mix.Task

  @shortdoc "Re-embeds all documents with current embedding config"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [batch_size: :integer, quiet: :boolean]
      )

    batch_size = Keyword.get(opts, :batch_size, 50)
    quiet = Keyword.get(opts, :quiet, false)

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

    Mix.shell().info("Re-embedding chunks...")

    case Arcana.Maintenance.reembed(repo, batch_size: batch_size, progress: progress_fn) do
      {:ok, %{rechunked_documents: docs, total_chunks: total}} ->
        unless quiet, do: IO.puts("")

        if docs > 0 do
          Mix.shell().info("Rechunked #{docs} documents.")
        end

        Mix.shell().info("Done! #{total} chunks total.")

      {:error, reason} ->
        Mix.raise("Re-embedding failed: #{inspect(reason)}")
    end
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
