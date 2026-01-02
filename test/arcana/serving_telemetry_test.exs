defmodule Arcana.ServingTelemetryTest do
  # Requires real Nx.Serving - run with: mix test --include serving
  use ExUnit.Case, async: false

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

    _embedding = Serving.embed("test text")

    assert_receive {:telemetry, [:arcana, :embed, :start], start_measurements, start_metadata}
    assert is_integer(start_measurements.system_time)
    assert start_metadata.text == "test text"

    assert_receive {:telemetry, [:arcana, :embed, :stop], stop_measurements, stop_metadata}
    assert is_integer(stop_measurements.duration)
    assert stop_metadata.dimensions == 384

    :telemetry.detach(ref)
  end
end
