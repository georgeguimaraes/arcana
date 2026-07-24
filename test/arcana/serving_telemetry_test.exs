defmodule Arcana.ServingTelemetryTest do
  # Requires real Nx.Serving - run with: mix test --include serving
  use ExUnit.Case, async: true

  alias Arcana.Embeddings.Serving

  @moduletag :serving

  setup_all do
    # Start the serving with a small model for this test
    {:ok, pid} = Serving.start_link(model: "sentence-transformers/all-MiniLM-L6-v2")

    on_exit(fn -> GenServer.stop(pid) end)
    :ok
  end

  test "emits [:arcana, :embed, :start] and [:arcana, :embed, :stop] events" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      ref,
      [
        [:arcana, :embed, :start],
        [:arcana, :embed, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)

    # Concurrent tests also emit [:arcana, :embed] events (the test-env fake
    # embedder produces the same 384 dimensions), so pin the start event by
    # our unique text and the stop event by the shared span context.
    text = "serving telemetry text #{System.unique_integer([:positive])}"
    _embedding = Serving.embed(text)

    assert_receive {:telemetry, [:arcana, :embed, :start], start_measurements,
                    %{text: ^text} = start_metadata}

    assert is_integer(start_measurements.system_time)

    span_context = start_metadata.telemetry_span_context

    assert_receive {:telemetry, [:arcana, :embed, :stop], stop_measurements,
                    %{telemetry_span_context: ^span_context} = stop_metadata}

    assert is_integer(stop_measurements.duration)
    assert stop_metadata.dimensions == 384
  end
end
