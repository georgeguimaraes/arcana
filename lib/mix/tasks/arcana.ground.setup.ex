defmodule Mix.Tasks.Arcana.Ground.Setup do
  @shortdoc "Downloads the LettuceDetect ONNX model for hallucination grounding"

  @moduledoc """
  Downloads pre-exported LettuceDetect ONNX model files from HuggingFace Hub.

      $ mix arcana.ground.setup

  This downloads `model.onnx`, `model.onnx.data`, and `tokenizer.json` to
  `priv/models/lettucedect/` so you can use `Agent.ground/2` without needing
  Python or torch installed.

  ## Options

    * `--output-dir` - Where to save the model files (default: `priv/models/lettucedect`)
    * `--force` - Re-download files even if they already exist
  """

  use Mix.Task

  @hf_repo "georgeguimaraes/lettucedect-onnx"
  @hf_base_url "https://huggingface.co/#{@hf_repo}/resolve/main"

  @files [
    {"model.onnx", "~2.8 MB"},
    {"model.onnx.data", "~598 MB"},
    {"tokenizer.json", "~3.6 MB"}
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [output_dir: :string, force: :boolean]
      )

    output_dir = opts[:output_dir] || "priv/models/lettucedect"
    force? = opts[:force] || false

    Mix.shell().info("Setting up LettuceDetect ONNX model for grounding...\n")

    File.mkdir_p!(output_dir)
    Application.ensure_all_started(:req)

    results =
      Enum.map(@files, fn {filename, size_hint} ->
        path = Path.join(output_dir, filename)

        if File.exists?(path) and not force? do
          Mix.shell().info("  #{filename} already exists, skipping")
          :skipped
        else
          url = "#{@hf_base_url}/#{filename}"
          Mix.shell().info("  Downloading #{filename} (#{size_hint})...")
          download_file(url, path)
        end
      end)

    if Enum.any?(results, &(&1 == :error)) do
      Mix.shell().error("\nSome files failed to download. Re-run or use --force to retry.")
    else
      Mix.shell().info("""

      Done! Model files saved to #{output_dir}/

      Configure in your config:

          config :arcana, Arcana.Grounding.Serving,
            model_path: "#{output_dir}/model.onnx"
      """)
    end
  end

  defp download_file(url, path) do
    tmp_path = path <> ".download"

    case Req.get(url, into: File.stream!(tmp_path), redirect_log_level: false) do
      {:ok, %Req.Response{status: 200}} ->
        File.rename!(tmp_path, path)
        size = File.stat!(path).size |> format_bytes()
        Mix.shell().info("  #{Path.basename(path)} downloaded (#{size})")
        :ok

      {:ok, %Req.Response{status: status}} ->
        File.rm(tmp_path)
        Mix.shell().error("  Failed to download #{Path.basename(path)}: HTTP #{status}")
        :error

      {:error, reason} ->
        File.rm(tmp_path)
        Mix.shell().error("  Failed to download #{Path.basename(path)}: #{inspect(reason)}")
        :error
    end
  end

  defp format_bytes(bytes) when bytes >= 1_000_000_000,
    do: "#{Float.round(bytes / 1_000_000_000, 1)} GB"

  defp format_bytes(bytes) when bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp format_bytes(bytes) when bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 1)} KB"

  defp format_bytes(bytes),
    do: "#{bytes} B"
end
