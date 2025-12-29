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

    # Start the application
    {:ok, _} = Application.ensure_all_started(:arcana)

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
      {:ok, %{reembedded: count, total: total}} ->
        unless quiet, do: IO.puts("")
        Mix.shell().info("Done! Re-embedded #{count}/#{total} chunks.")

      {:error, {:embed_failed, chunk_id, reason}} ->
        Mix.raise("Failed to embed chunk #{chunk_id}: #{inspect(reason)}")

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

  defp format_info(%{type: :zai, model: model, dimensions: dims}) do
    "zai (#{model}, #{dims} dims)"
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
