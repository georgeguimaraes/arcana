# Telemetry and Observability

Arcana emits telemetry events for all operations, giving you visibility into performance, errors, and usage patterns. This guide covers setup options from quick debugging to full production monitoring.

## Quick Start

For immediate visibility, attach the built-in logger in your application startup:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  # Attach telemetry logger before starting supervision tree
  Arcana.Telemetry.Logger.attach()

  children = [
    MyApp.Repo,
    Arcana.Embedder.Local
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

This logs all Arcana operations with timing:

```
[info] [Arcana] search completed in 42ms (15 results)
[info] [Arcana] llm.complete completed in 1.23s [openai:gpt-4o-mini] ok (156 chars) prompt=892chars
[info] [Arcana] agent.rewrite completed in 235ms
[info] [Arcana] agent.expand completed in 2.15s ("machine learning ML models...")
[info] [Arcana] agent.search completed in 156ms (25 chunks)
[info] [Arcana] agent.rerank completed in 312ms (10/25 kept)
[info] [Arcana] agent.answer completed in 3.25s
[info] [Arcana] ask completed in 6.12s
```

### Logger Options

```elixir
Arcana.Telemetry.Logger.attach(
  level: :debug,           # Log level (default: :info)
  handler_id: "my-logger"  # Custom handler ID
)

# To stop logging
Arcana.Telemetry.Logger.detach()
```

## Event Reference

All events use `:telemetry.span/3`, which emits `:start`, `:stop`, and `:exception` variants automatically.

### Core Events

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:arcana, :ingest, :*]` | `system_time`, `duration` | `text`, `repo`, `collection`, `document`, `chunk_count` |
| `[:arcana, :search, :*]` | `system_time`, `duration` | `query`, `repo`, `mode`, `limit`, `results`, `result_count` |
| `[:arcana, :ask, :*]` | `system_time`, `duration` | `question`, `repo`, `answer`, `context_count` |
| `[:arcana, :embed, :*]` | `system_time`, `duration` | `text`, `dimensions` |
| `[:arcana, :llm, :complete, :*]` | `system_time`, `duration` | `model`, `prompt_length`, `success`, `response_length`, `error` |

### Agent Pipeline Events

Each step in the Agent pipeline emits its own events:

| Event | Metadata |
|-------|----------|
| `[:arcana, :agent, :rewrite, :*]` | `query` (rewritten) |
| `[:arcana, :agent, :select, :*]` | `selected` (collections) |
| `[:arcana, :agent, :expand, :*]` | `expanded_query` |
| `[:arcana, :agent, :decompose, :*]` | `sub_question_count` |
| `[:arcana, :agent, :search, :*]` | `total_chunks` |
| `[:arcana, :agent, :rerank, :*]` | `kept`, `original` |
| `[:arcana, :agent, :answer, :*]` | - |
| `[:arcana, :agent, :self_correct, :*]` | `attempt` |

### Exception Events

All `:exception` events include:
- `kind` - The exception type (`:error`, `:exit`, `:throw`)
- `reason` - The exception or error term
- `stacktrace` - Full stacktrace

## Custom Handlers

For more control, attach your own handlers:

```elixir
defmodule MyApp.ArcanaMetrics do
  require Logger

  def setup do
    events = [
      [:arcana, :ingest, :stop],
      [:arcana, :search, :stop],
      [:arcana, :ask, :stop],
      [:arcana, :embed, :stop],
      [:arcana, :llm, :complete, :stop],
      # Agent pipeline
      [:arcana, :agent, :rerank, :stop],
      [:arcana, :agent, :answer, :stop]
    ]

    :telemetry.attach_many("my-arcana-metrics", events, &handle_event/4, nil)
  end

  def handle_event([:arcana, :search, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    Logger.info("Search: #{metadata.result_count} results in #{duration_ms}ms",
      query: metadata.query,
      mode: metadata.mode
    )

    # Send to your metrics system
    :telemetry.execute([:my_app, :arcana, :search], %{
      duration_ms: duration_ms,
      result_count: metadata.result_count
    })
  end

  def handle_event([:arcana, :llm, :complete, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    if metadata.success do
      Logger.debug("LLM call to #{metadata.model}: #{duration_ms}ms")
    else
      Logger.warning("LLM call failed: #{metadata.error}")
    end
  end

  # ... handle other events
end
```

Call `MyApp.ArcanaMetrics.setup()` in your application startup.

## Phoenix LiveDashboard Integration

Add Arcana metrics to your LiveDashboard:

```elixir
# lib/my_app/telemetry.ex
defmodule MyApp.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      # Arcana core operations
      summary("arcana.ingest.stop.duration",
        unit: {:native, :millisecond},
        tags: [:collection]
      ),
      summary("arcana.search.stop.duration",
        unit: {:native, :millisecond},
        tags: [:mode]
      ),
      counter("arcana.search.stop.result_count"),
      summary("arcana.ask.stop.duration",
        unit: {:native, :millisecond}
      ),

      # Embedding performance
      summary("arcana.embed.stop.duration",
        unit: {:native, :millisecond}
      ),

      # LLM calls (often the slowest part)
      summary("arcana.llm.complete.stop.duration",
        unit: {:native, :millisecond},
        tags: [:model]
      ),
      counter("arcana.llm.complete.stop.prompt_length"),

      # Agent pipeline steps
      summary("arcana.agent.rerank.stop.duration",
        unit: {:native, :millisecond}
      ),
      last_value("arcana.agent.rerank.stop.kept"),
      summary("arcana.agent.answer.stop.duration",
        unit: {:native, :millisecond}
      )
    ]
  end
end
```

Configure LiveDashboard to use these metrics:

```elixir
# lib/my_app_web/router.ex
live_dashboard "/dashboard",
  metrics: MyApp.Telemetry
```

## Prometheus Integration

For production monitoring with Prometheus, use `prom_ex`:

```elixir
# mix.exs
{:prom_ex, "~> 1.9"}
```

```elixir
# lib/my_app/prom_ex.ex
defmodule MyApp.PromEx do
  use PromEx, otp_app: :my_app

  @impl true
  def plugins do
    [
      # Default plugins
      PromEx.Plugins.Application,
      PromEx.Plugins.Beam,
      # Add custom Arcana metrics
      MyApp.PromEx.ArcanaPlugin
    ]
  end

  @impl true
  def dashboards do
    [
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"}
    ]
  end
end
```

```elixir
# lib/my_app/prom_ex/arcana_plugin.ex
defmodule MyApp.PromEx.ArcanaPlugin do
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    Event.build(
      :arcana_event_metrics,
      [
        distribution(
          [:arcana, :search, :duration, :milliseconds],
          event_name: [:arcana, :search, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:mode],
          tag_values: fn metadata -> %{mode: metadata[:mode] || :semantic} end
        ),
        distribution(
          [:arcana, :llm, :complete, :duration, :milliseconds],
          event_name: [:arcana, :llm, :complete, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:model, :success],
          tag_values: fn metadata ->
            %{model: metadata[:model] || "unknown", success: metadata[:success]}
          end
        ),
        counter(
          [:arcana, :ingest, :chunks, :total],
          event_name: [:arcana, :ingest, :stop],
          measurement: fn _measurements, metadata -> metadata[:chunk_count] || 0 end
        )
      ]
    )
  end
end
```

## Debugging Performance Issues

### Identify Slow Operations

The built-in logger makes it easy to spot bottlenecks:

```
[info] [Arcana] embed completed in 45ms (384 dims)
[info] [Arcana] search completed in 12ms (10 results)
[info] [Arcana] llm.complete completed in 3.2s [openai:gpt-4o] ok (1892 chars)
[info] [Arcana] ask completed in 3.3s
```

In this example, the LLM call dominates total time (3.2s of 3.3s).

### Track Agent Pipeline Steps

For agentic RAG, each pipeline step is instrumented:

```
[info] [Arcana] agent.rewrite completed in 180ms ("what are elixir macros")
[info] [Arcana] agent.expand completed in 220ms ("elixir macros metaprogramming...")
[info] [Arcana] agent.search completed in 35ms (25 chunks)
[info] [Arcana] agent.rerank completed in 890ms (8/25 kept)
[info] [Arcana] agent.answer completed in 2.1s
```

Here, reranking takes 890ms - if this is too slow, consider:
- Reducing chunks before reranking (lower search limit)
- Using a faster reranking threshold
- Implementing a custom reranker

### Monitor LLM Costs

Track prompt sizes to estimate API costs:

```elixir
def handle_event([:arcana, :llm, :complete, :stop], measurements, metadata, _config) do
  # Rough token estimate (4 chars per token)
  prompt_tokens = div(metadata.prompt_length || 0, 4)
  response_tokens = div(metadata.response_length || 0, 4)

  Logger.info("LLM usage",
    model: metadata.model,
    prompt_tokens: prompt_tokens,
    response_tokens: response_tokens,
    success: metadata.success
  )
end
```

## Error Tracking

Handle exceptions to send to your error tracking service:

```elixir
def setup do
  exception_events = [
    [:arcana, :ingest, :exception],
    [:arcana, :search, :exception],
    [:arcana, :ask, :exception],
    [:arcana, :llm, :complete, :exception]
  ]

  :telemetry.attach_many("arcana-errors", exception_events, &handle_exception/4, nil)
end

def handle_exception(event, _measurements, metadata, _config) do
  # Send to Sentry, Honeybadger, etc.
  Sentry.capture_message("Arcana error",
    extra: %{
      event: inspect(event),
      kind: metadata.kind,
      reason: inspect(metadata.reason)
    }
  )
end
```

## Best Practices

1. **Start with the built-in logger** - It's zero-config and helps you understand what's happening

2. **Focus on LLM latency** - This is usually the bottleneck; track it closely

3. **Monitor reranking** - If using Agent.rerank/2, watch the kept/original ratio

4. **Track by collection** - Tag metrics with collection names to identify slow document sets

5. **Set up alerts** - Alert on LLM failures and unusually slow operations

6. **Log in production** - Keep at least `:info` level logging for Arcana to debug issues
