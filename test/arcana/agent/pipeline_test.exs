defmodule Arcana.Agent.PipelineTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent

  describe "pipeline" do
    setup do
      # Use words that will overlap with the query for mock embeddings
      # Mock embeddings use word hashes, so shared words = higher similarity
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language that runs on BEAM.",
          repo: Arcana.TestRepo
        )

      :ok
    end

    test "full pipeline from question to answer" do
      llm = fn prompt ->
        if prompt =~ "BEAM" do
          {:ok, "Elixir runs on the BEAM VM."}
        else
          {:ok, "Unknown"}
        end
      end

      # Query shares "Elixir", "programming", "language" with document
      ctx =
        Agent.new("What programming language is Elixir?",
          repo: Arcana.TestRepo,
          llm: llm
        )
        |> Agent.search()
        |> Agent.answer()

      assert ctx.answer == "Elixir runs on the BEAM VM."
      refute Enum.empty?(ctx.results)
      refute Enum.empty?(ctx.context_used)
    end
  end

  describe "telemetry" do
    setup do
      {:ok, _doc} = Arcana.ingest("Telemetry test content", repo: Arcana.TestRepo)
      :ok
    end

    test "emits telemetry events for search" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :search, :start],
          [:arcana, :agent, :search, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Agent.new("test", repo: Arcana.TestRepo, llm: &mock_llm/1)
      |> Agent.search()

      assert_receive {:telemetry, [:arcana, :agent, :search, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :search, :stop], _, metadata}
      assert is_integer(metadata.result_count)

      :telemetry.detach(ref)
    end

    test "emits telemetry events for answer" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :agent, :answer, :start],
          [:arcana, :agent, :answer, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, "Answer"} end

      Agent.new("test", repo: Arcana.TestRepo, llm: llm)
      |> Agent.search()
      |> Agent.answer()

      assert_receive {:telemetry, [:arcana, :agent, :answer, :start], _, _}
      assert_receive {:telemetry, [:arcana, :agent, :answer, :stop], _, metadata}
      assert is_integer(metadata.context_chunk_count)

      :telemetry.detach(ref)
    end
  end

  defp mock_llm(_prompt), do: {:ok, "mock response"}
end
