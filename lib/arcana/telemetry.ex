defmodule Arcana.Telemetry do
  @moduledoc """
  Telemetry events emitted by Arcana.

  Arcana uses the standard `:telemetry` library to emit events for observability.
  You can attach handlers to these events for logging, metrics, or tracing.

  ## Events

  All events are emitted using `:telemetry.span/3`, which automatically generates
  `:start`, `:stop`, and `:exception` events.

  ### Ingest Events

  * `[:arcana, :ingest, :start]` - Emitted when document ingestion begins.
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{text: String.t(), repo: module(), collection: String.t()}`

  * `[:arcana, :ingest, :stop]` - Emitted when document ingestion completes.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{document: Document.t(), chunk_count: integer}`

  * `[:arcana, :ingest, :exception]` - Emitted when document ingestion fails.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{kind: atom(), reason: term(), stacktrace: list()}`

  ### Search Events

  * `[:arcana, :search, :start]` - Emitted when a search query begins.
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{query: String.t(), repo: module(), mode: atom(), limit: integer}`

  * `[:arcana, :search, :stop]` - Emitted when a search query completes.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{results: list(), result_count: integer}`

  * `[:arcana, :search, :exception]` - Emitted when a search query fails.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{kind: atom(), reason: term(), stacktrace: list()}`

  ### Ask Events (RAG)

  * `[:arcana, :ask, :start]` - Emitted when a RAG question begins.
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{question: String.t(), repo: module()}`

  * `[:arcana, :ask, :stop]` - Emitted when a RAG question completes.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{answer: String.t(), context_count: integer}`

  * `[:arcana, :ask, :exception]` - Emitted when a RAG question fails.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{kind: atom(), reason: term(), stacktrace: list()}`

  ### Embed Events

  * `[:arcana, :embed, :start]` - Emitted when embedding generation begins.
    * Measurement: `%{system_time: integer}`
    * Metadata: `%{text: String.t()}`

  * `[:arcana, :embed, :stop]` - Emitted when embedding generation completes.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{dimensions: integer}`

  * `[:arcana, :embed, :exception]` - Emitted when embedding generation fails.
    * Measurement: `%{duration: integer}`
    * Metadata: `%{kind: atom(), reason: term(), stacktrace: list()}`

  ## Quick Start with Built-in Logger

  For quick setup, use the built-in logger:

      # In your application's start/2
      Arcana.Telemetry.Logger.attach()

  This logs all events with timing info. See `Arcana.Telemetry.Logger` for options.

  ## Custom Handler

  For custom handling, attach your own handler:

      defmodule MyApp.ArcanaLogger do
        require Logger

        def setup do
          events = [
            [:arcana, :ingest, :stop],
            [:arcana, :search, :stop],
            [:arcana, :ask, :stop],
            [:arcana, :embed, :stop]
          ]

          :telemetry.attach_many("arcana-logger", events, &handle_event/4, nil)
        end

        def handle_event([:arcana, :ingest, :stop], measurements, metadata, _config) do
          Logger.info("Ingested document \#{metadata.document.id} with \#{metadata.chunk_count} chunks in \#{format_duration(measurements.duration)}")
        end

        def handle_event([:arcana, :search, :stop], measurements, metadata, _config) do
          Logger.info("Search returned \#{metadata.result_count} results in \#{format_duration(measurements.duration)}")
        end

        def handle_event([:arcana, :ask, :stop], measurements, metadata, _config) do
          Logger.info("RAG answered with \#{metadata.context_count} context chunks in \#{format_duration(measurements.duration)}")
        end

        def handle_event([:arcana, :embed, :stop], measurements, _metadata, _config) do
          Logger.debug("Generated embedding in \#{format_duration(measurements.duration)}")
        end

        defp format_duration(duration) do
          duration
          |> System.convert_time_unit(:native, :millisecond)
          |> then(&"\#{&1}ms")
        end
      end

  Then call `MyApp.ArcanaLogger.setup()` in your application startup.

  ## Integration with Metrics Libraries

  These telemetry events work with metrics libraries like:

  * `telemetry_metrics` - Define metrics based on these events
  * `telemetry_poller` - Periodically report metrics
  * `prom_ex` - Export to Prometheus

  Example with `telemetry_metrics`:

      defmodule MyApp.Metrics do
        import Telemetry.Metrics

        def metrics do
          [
            counter("arcana.ingest.stop.duration", unit: {:native, :millisecond}),
            counter("arcana.search.stop.duration", unit: {:native, :millisecond}),
            summary("arcana.search.stop.result_count"),
            distribution("arcana.embed.stop.duration", unit: {:native, :millisecond})
          ]
        end
      end
  """

  @doc """
  Wraps a function call with telemetry span events.

  This is a convenience function used internally by Arcana to emit
  consistent telemetry events.
  """
  def span(event_prefix, start_metadata, fun)
      when is_list(event_prefix) and is_function(fun, 0) do
    :telemetry.span(event_prefix, start_metadata, fn ->
      result = fun.()
      {result, %{}}
    end)
  end

  @doc """
  Wraps a function call with telemetry span events, allowing custom stop metadata.

  The function should return `{result, stop_metadata}` where `stop_metadata`
  is a map of additional metadata to include in the stop event.
  """
  def span_with_metadata(event_prefix, start_metadata, fun)
      when is_list(event_prefix) and is_function(fun, 0) do
    :telemetry.span(event_prefix, start_metadata, fun)
  end
end
