defmodule Arcana.TelemetryTest do
  # async: false because telemetry events are global and can interfere
  # across parallel tests (e.g., ask test's internal search can trigger
  # events that the search test receives)
  use Arcana.DataCase, async: false

  alias Arcana.Embeddings.Serving

  describe "ingest telemetry" do
    test "emits [:arcana, :ingest, :start] and [:arcana, :ingest, :stop] events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :ingest, :start],
          [:arcana, :ingest, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, document} = Arcana.ingest("Test content for telemetry", repo: Arcana.TestRepo)

      assert_receive {:telemetry, [:arcana, :ingest, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.text == "Test content for telemetry"
      assert start_metadata.repo == Arcana.TestRepo

      assert_receive {:telemetry, [:arcana, :ingest, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.document.id == document.id

      :telemetry.detach(ref)
    end
  end

  describe "search telemetry" do
    test "emits [:arcana, :search, :start] and [:arcana, :search, :stop] events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :search, :start],
          [:arcana, :search, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _} = Arcana.ingest("Elixir programming language", repo: Arcana.TestRepo)
      {:ok, results} = Arcana.search("Elixir", repo: Arcana.TestRepo)

      assert_receive {:telemetry, [:arcana, :search, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.query == "Elixir"
      assert start_metadata.repo == Arcana.TestRepo

      assert_receive {:telemetry, [:arcana, :search, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.results == results
      assert is_integer(stop_metadata.result_count)

      :telemetry.detach(ref)
    end
  end

  describe "ask telemetry" do
    test "emits [:arcana, :ask, :start] and [:arcana, :ask, :stop] events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :ask, :start],
          [:arcana, :ask, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      {:ok, _} = Arcana.ingest("The capital of France is Paris.", repo: Arcana.TestRepo)

      test_llm = fn _prompt, _context ->
        {:ok, "Paris is the capital of France."}
      end

      {:ok, answer, _results} =
        Arcana.ask("What is the capital of France?", repo: Arcana.TestRepo, llm: test_llm)

      assert_receive {:telemetry, [:arcana, :ask, :start], start_measurements, start_metadata}
      assert is_integer(start_measurements.system_time)
      assert start_metadata.question == "What is the capital of France?"
      assert start_metadata.repo == Arcana.TestRepo

      assert_receive {:telemetry, [:arcana, :ask, :stop], stop_measurements, stop_metadata}
      assert is_integer(stop_measurements.duration)
      assert stop_metadata.answer == answer

      :telemetry.detach(ref)
    end
  end

  describe "embed telemetry" do
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
      assert stop_metadata.dimensions == 32

      :telemetry.detach(ref)
    end
  end
end
