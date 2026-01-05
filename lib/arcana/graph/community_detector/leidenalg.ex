defmodule Arcana.Graph.CommunityDetector.Leidenalg do
  @moduledoc """
  Leiden algorithm implementation using Python leidenalg.

  This implementation shells out to Python's leidenalg library, which provides
  a battle-tested Leiden implementation with the proper refinement phase.
  Expected performance: <1 second for 15k entities (vs 25+ minutes with ex_leiden).

  Requires `uv` (https://docs.astral.sh/uv/) to be installed.

  ## Usage

      detector = {Arcana.Graph.CommunityDetector.Leidenalg, resolution: 1.0}
      {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

  ## Options

    - `:resolution` - Controls community granularity (default: 1.0)
      Higher values produce smaller communities
    - `:n_iterations` - Number of iterations (-1 for convergence, default: -1)

  ## Performance

  The Python leidenalg library is the reference implementation and handles
  sparse graphs efficiently. For a 15k entity / 20k relationship graph:
  - ex_leiden (Elixir): ~25 minutes (broken - dense matrix)
  - leidenalg (Python): <1 second

  """

  @behaviour Arcana.Graph.CommunityDetector

  require Logger

  @script_path "priv/scripts/leidenalg_detect.py"

  @impl true
  def detect([], _relationships, _opts), do: {:ok, []}

  def detect(entities, relationships, opts) do
    resolution = Keyword.get(opts, :resolution, 1.0)
    n_iterations = Keyword.get(opts, :n_iterations, -1)

    edges = to_edges(entities, relationships)

    Logger.info(
      "[Leidenalg] Starting: #{length(entities)} entities, #{length(edges)} edges, " <>
        "resolution=#{resolution}"
    )

    :telemetry.span(
      [:arcana, :graph, :community_detection],
      %{entity_count: length(entities), detector: :leidenalg},
      fn ->
        start_time = System.monotonic_time(:millisecond)

        result = run_python_detector(edges, resolution, n_iterations)

        elapsed = System.monotonic_time(:millisecond) - start_time

        case result do
          {:ok, communities} ->
            Logger.info("[Leidenalg] Completed in #{elapsed}ms: #{length(communities)} communities")
            {{:ok, communities}, %{community_count: length(communities), elapsed_ms: elapsed}}

          {:error, reason} ->
            Logger.error("[Leidenalg] Failed after #{elapsed}ms: #{inspect(reason)}")
            {{:error, reason}, %{community_count: 0, elapsed_ms: elapsed}}
        end
      end
    )
  end

  defp to_edges(entities, relationships) do
    entity_ids = MapSet.new(entities, & &1.id)

    relationships
    |> Enum.filter(fn rel ->
      MapSet.member?(entity_ids, rel.source_id) and
        MapSet.member?(entity_ids, rel.target_id)
    end)
    |> Enum.map(fn rel ->
      weight = Map.get(rel, :strength, 1) || 1
      [rel.source_id, rel.target_id, weight]
    end)
  end

  defp run_python_detector(edges, resolution, n_iterations) do
    script_path = script_path()

    unless File.exists?(script_path) do
      {:error, "Python script not found at #{script_path}"}
    else
      input =
        Jason.encode!(%{
          edges: edges,
          resolution: resolution,
          n_iterations: n_iterations
        })

      case run_uv_script(script_path, input) do
        {:ok, output} ->
          parse_output(output)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp run_uv_script(script_path, input) do
    # Write input to temp file (large JSON doesn't work well with shell piping)
    tmp_path = Path.join(System.tmp_dir!(), "leidenalg_input_#{:erlang.unique_integer([:positive])}.json")

    try do
      File.write!(tmp_path, input)

      # Run uv with input file redirected to stdin
      case System.cmd("sh", ["-c", "cat #{tmp_path} | uv run --script #{script_path}"],
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, output}

        {output, exit_code} ->
          {:error, "Python script failed (exit #{exit_code}): #{output}"}
      end
    after
      File.rm(tmp_path)
    end
  rescue
    e ->
      {:error, "Failed to run uv: #{inspect(e)}. Is uv installed?"}
  end

  defp parse_output(output) do
    case Jason.decode(output) do
      {:ok, %{"communities" => communities, "stats" => stats}} ->
        Logger.debug("[Leidenalg] Stats: #{inspect(stats)}")

        formatted =
          Enum.map(communities, fn %{"level" => level, "entity_ids" => entity_ids} ->
            %{level: level, entity_ids: entity_ids}
          end)

        {:ok, formatted}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:error, decode_error} ->
        {:error, "Failed to parse Python output: #{inspect(decode_error)}"}
    end
  end

  defp script_path do
    case :code.priv_dir(:arcana) do
      {:error, _} ->
        # Development: use relative path
        Path.join([File.cwd!(), @script_path])

      priv_dir ->
        # Production: use priv directory
        Path.join([priv_dir, "scripts", "leidenalg_detect.py"])
    end
  end
end
