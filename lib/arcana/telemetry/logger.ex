defmodule Arcana.Telemetry.Logger do
  @moduledoc """
  Ready-to-use telemetry logger for Arcana events.

  Logs all Arcana operations with timing information to help identify
  performance bottlenecks.

  ## Usage

  Add to your application's `start/2` function:

      def start(_type, _args) do
        Arcana.Telemetry.Logger.attach()

        children = [
          # ...
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end

  ## Example Output

      [info] [Arcana] search completed in 42ms (15 results)
      [info] [Arcana] llm.complete completed in 1.23s [zai:glm-4.7] ok (156 chars) prompt=892chars
      [info] [Arcana] agent.rewrite completed in 235ms
      [info] [Arcana] llm.complete completed in 2.1s [zai:glm-4.7] ok (45 chars) prompt=1204chars
      [info] [Arcana] agent.expand completed in 2.15s (3 queries)
      [info] [Arcana] agent.search completed in 156ms (25 chunks)
      [info] [Arcana] agent.rerank completed in 312ms (10/25 kept)
      [info] [Arcana] llm.complete completed in 3.2s [zai:glm-4.7] ok (1892 chars) prompt=4521chars
      [info] [Arcana] agent.answer completed in 3.25s
      [info] [Arcana] ask completed in 6.12s

  ## Options

  You can customize the logger by passing options to `attach/1`:

      Arcana.Telemetry.Logger.attach(
        level: :debug,           # Log level (default: :info)
        handler_id: "my-logger"  # Custom handler ID (default: "arcana-telemetry-logger")
      )

  ## Detaching

  To stop logging, call:

      Arcana.Telemetry.Logger.detach()
  """

  require Logger

  @default_handler_id "arcana-telemetry-logger"

  @events [
    # Core operations
    [:arcana, :ingest, :stop],
    [:arcana, :search, :stop],
    [:arcana, :ask, :stop],
    [:arcana, :embed, :stop],
    [:arcana, :embed_batch, :stop],
    # LLM calls
    [:arcana, :llm, :complete, :stop],
    # Agent pipeline
    [:arcana, :agent, :rewrite, :stop],
    [:arcana, :agent, :select, :stop],
    [:arcana, :agent, :expand, :stop],
    [:arcana, :agent, :decompose, :stop],
    [:arcana, :agent, :search, :stop],
    [:arcana, :agent, :rerank, :stop],
    [:arcana, :agent, :answer, :stop],
    [:arcana, :agent, :self_correct, :stop]
  ]

  @doc """
  Attaches telemetry handlers for logging Arcana events.

  ## Options

    * `:level` - The log level to use (default: `:info`)
    * `:handler_id` - Custom handler ID (default: `"arcana-telemetry-logger"`)

  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    handler_id = Keyword.get(opts, :handler_id, @default_handler_id)
    level = Keyword.get(opts, :level, :info)

    :telemetry.attach_many(
      handler_id,
      @events,
      &__MODULE__.handle_event/4,
      %{level: level, handler_id: handler_id}
    )
  end

  @doc """
  Detaches the telemetry handlers.

  ## Options

    * `:handler_id` - The handler ID to detach (default: `"arcana-telemetry-logger"`)

  """
  @spec detach(keyword()) :: :ok | {:error, :not_found}
  def detach(opts \\ []) do
    handler_id = Keyword.get(opts, :handler_id, @default_handler_id)
    :telemetry.detach(handler_id)
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    duration = format_duration(measurements[:duration])
    event_name = format_event_name(event)
    details = extract_details(event_name, metadata)

    message =
      if details != "",
        do: "[Arcana] #{event_name} completed in #{duration} #{details}",
        else: "[Arcana] #{event_name} completed in #{duration}"

    Logger.log(config.level, message)
  end

  defp format_duration(nil), do: "?"

  defp format_duration(duration_ns) do
    duration_ms = System.convert_time_unit(duration_ns, :native, :millisecond)

    cond do
      duration_ms >= 1000 -> "#{Float.round(duration_ms / 1000, 2)}s"
      duration_ms >= 1 -> "#{duration_ms}ms"
      true -> "<1ms"
    end
  end

  defp format_event_name([:arcana | rest]) do
    rest
    |> Enum.reject(&(&1 == :stop))
    |> Enum.map_join(".", &Atom.to_string/1)
  end

  defp extract_details("ingest", meta) do
    "(#{meta[:chunks_count] || meta[:chunk_count] || "?"} chunks)"
  end

  defp extract_details("search", meta) do
    "(#{meta[:results_count] || meta[:result_count] || "?"} results)"
  end

  defp extract_details("ask", meta) do
    case meta[:answer] do
      answer when is_binary(answer) and byte_size(answer) > 0 ->
        preview = String.slice(answer, 0, 50)

        if String.length(answer) > 50,
          do: "(\"#{preview}...\")",
          else: "(\"#{preview}\")"

      _ ->
        ""
    end
  end

  defp extract_details("embed", meta) do
    "(#{meta[:dimensions] || "?"} dims)"
  end

  defp extract_details("embed_batch", meta) do
    "(#{meta[:count] || "?"} texts)"
  end

  defp extract_details("llm.complete", meta) do
    model = meta[:model] || "?"
    prompt_len = meta[:prompt_length] || "?"
    status = if meta[:success], do: "ok", else: "error"

    response_info =
      if meta[:success] do
        "(#{meta[:response_length] || "?"} chars)"
      else
        "(#{meta[:error] || "unknown error"})"
      end

    "[#{model}] #{status} #{response_info} prompt=#{prompt_len}chars"
  end

  defp extract_details("agent.rewrite", meta) do
    case meta[:query] do
      query when is_binary(query) and byte_size(query) > 0 ->
        preview = String.slice(query, 0, 40)
        if String.length(query) > 40, do: "(\"#{preview}...\")", else: "(\"#{preview}\")"

      _ ->
        ""
    end
  end

  defp extract_details("agent.select", meta) do
    count = length(meta[:selected] || [])
    "(#{count} collection#{if count == 1, do: "", else: "s"})"
  end

  defp extract_details("agent.expand", meta) do
    count = length(meta[:queries] || [])
    "(#{count} quer#{if count == 1, do: "y", else: "ies"})"
  end

  defp extract_details("agent.decompose", meta) do
    count = length(meta[:subquestions] || [])
    "(#{count} subquestion#{if count == 1, do: "", else: "s"})"
  end

  defp extract_details("agent.search", meta) do
    "(#{meta[:total_chunks] || "?"} chunks)"
  end

  defp extract_details("agent.rerank", meta) do
    "(#{meta[:kept] || "?"}/#{meta[:original] || "?"} kept)"
  end

  defp extract_details("agent.answer", _meta), do: ""

  defp extract_details("agent.self_correct", meta) do
    "(attempt #{meta[:attempt] || "?"})"
  end

  defp extract_details(_event, _meta), do: ""
end
