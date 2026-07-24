defmodule Arcana.TelemetryTest do
  # Telemetry handlers receive events from every process, including other
  # async tests running concurrently. Each assertion pins the event to this
  # test's unique payload so foreign events never match.
  use Arcana.DataCase, async: true

  defp attach(events) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach_many(
      ref,
      events,
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  describe "ingest telemetry" do
    test "emits [:arcana, :ingest, :start] and [:arcana, :ingest, :stop] events" do
      attach([[:arcana, :ingest, :start], [:arcana, :ingest, :stop]])

      text = "Test content for telemetry #{System.unique_integer([:positive])}"
      {:ok, document} = Arcana.ingest(text, repo: Arcana.TestRepo)
      id = document.id

      assert_receive {:telemetry, [:arcana, :ingest, :start], start_measurements,
                      %{text: ^text} = start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.repo == Arcana.TestRepo

      assert_receive {:telemetry, [:arcana, :ingest, :stop], stop_measurements,
                      %{document: %{id: ^id}}}

      assert is_integer(stop_measurements.duration)
    end
  end

  describe "search telemetry" do
    test "emits [:arcana, :search, :start] and [:arcana, :search, :stop] events" do
      attach([[:arcana, :search, :start], [:arcana, :search, :stop]])

      query = "Elixir telemetry query #{System.unique_integer([:positive])}"
      {:ok, _} = Arcana.ingest("Elixir programming language", repo: Arcana.TestRepo)
      {:ok, results} = Arcana.search(query, repo: Arcana.TestRepo)

      assert_receive {:telemetry, [:arcana, :search, :start], start_measurements,
                      %{query: ^query} = start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.repo == Arcana.TestRepo

      # The stop metadata doesn't carry the query; pin it to our start
      # event via the span context :telemetry.span puts in both.
      span_context = start_metadata.telemetry_span_context

      assert_receive {:telemetry, [:arcana, :search, :stop], stop_measurements,
                      %{telemetry_span_context: ^span_context} = stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.results == results
      assert is_integer(stop_metadata.result_count)
    end
  end

  describe "ask telemetry" do
    test "emits [:arcana, :ask, :start] and [:arcana, :ask, :stop] events" do
      attach([[:arcana, :ask, :start], [:arcana, :ask, :stop]])

      question = "What is the capital of France? #{System.unique_integer([:positive])}"
      unique_answer = "Paris answer #{System.unique_integer([:positive])}"

      {:ok, _} = Arcana.ingest("The capital of France is Paris.", repo: Arcana.TestRepo)

      test_llm = fn _prompt, _context -> {:ok, unique_answer} end

      {:ok, answer, _results} =
        Arcana.ask(question, repo: Arcana.TestRepo, llm: test_llm)

      assert_receive {:telemetry, [:arcana, :ask, :start], start_measurements,
                      %{question: ^question} = start_metadata}

      assert is_integer(start_measurements.system_time)
      assert start_metadata.repo == Arcana.TestRepo

      assert_receive {:telemetry, [:arcana, :ask, :stop], stop_measurements,
                      %{answer: ^unique_answer} = stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.answer == answer
    end
  end
end
