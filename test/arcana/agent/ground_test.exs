defmodule Arcana.Agent.GroundTest do
  use ExUnit.Case, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context
  alias Arcana.Grounding.Result

  describe "ground/2" do
    test "grounds answer with custom grounder function" do
      grounder = fn answer, chunks, opts ->
        assert answer == "Elixir is a functional language."
        assert length(chunks) > 0
        assert Keyword.get(opts, :question) == "What is Elixir?"

        {:ok, %Result{score: 0.95, hallucinated_spans: [], faithful_spans: [], token_labels: []}}
      end

      ctx =
        %Context{
          question: "What is Elixir?",
          answer: "Elixir is a functional language.",
          context_used: [%{id: 1, text: "Elixir is a functional programming language."}]
        }
        |> Agent.ground(grounder: grounder)

      assert ctx.grounding.score == 0.95
      assert ctx.grounding.hallucinated_spans == []
      assert ctx.grounding.faithful_spans == []
      assert is_nil(ctx.error)
    end

    test "passes hallucinated spans through" do
      spans = [%{text: "invented in 2010", start: 10, end: 26, score: 0.87}]

      grounder = fn _answer, _chunks, _opts ->
        {:ok, %Result{score: 0.8, hallucinated_spans: spans, token_labels: []}}
      end

      ctx =
        %Context{
          question: "When was Elixir created?",
          answer: "Elixir was invented in 2010 by José Valim.",
          context_used: [%{id: 1, text: "José Valim created Elixir in 2011."}]
        }
        |> Agent.ground(grounder: grounder)

      assert ctx.grounding.score == 0.8
      assert length(ctx.grounding.hallucinated_spans) == 1
      assert hd(ctx.grounding.hallucinated_spans).text == "invented in 2010"
    end

    test "faithful_spans populated by grounder" do
      faithful = [
        %{
          text: "functional language",
          start: 0,
          end: 19,
          score: 0.95,
          sources: [%{chunk_id: 1, score: 1.0}]
        }
      ]

      grounder = fn _answer, _chunks, _opts ->
        {:ok, %Result{score: 0.95, hallucinated_spans: [], faithful_spans: faithful}}
      end

      ctx =
        %Context{
          question: "What is Elixir?",
          answer: "functional language built on BEAM",
          context_used: [%{id: 1, text: "Elixir is a functional language."}]
        }
        |> Agent.ground(grounder: grounder)

      assert length(ctx.grounding.faithful_spans) == 1
      assert hd(ctx.grounding.faithful_spans).text == "functional language"
      assert hd(ctx.grounding.faithful_spans).sources == [%{chunk_id: 1, score: 1.0}]
    end

    test "accepts custom grounder module" do
      defmodule TestGrounder do
        @behaviour Arcana.Agent.Grounder

        @impl Arcana.Agent.Grounder
        def ground(_answer, _chunks, _opts) do
          {:ok, %Result{score: 1.0, hallucinated_spans: [], token_labels: []}}
        end
      end

      ctx =
        %Context{
          question: "test",
          answer: "test answer",
          context_used: [%{id: 1, text: "test context"}]
        }
        |> Agent.ground(grounder: TestGrounder)

      assert ctx.grounding.score == 1.0
    end

    test "skips if context has error" do
      ctx =
        %Context{
          question: "test",
          answer: "test answer",
          error: :previous_error
        }
        |> Agent.ground(grounder: fn _, _, _ -> raise "should not be called" end)

      assert ctx.error == :previous_error
      assert is_nil(ctx.grounding)
    end

    test "skips if no answer" do
      ctx =
        %Context{
          question: "test",
          answer: nil
        }
        |> Agent.ground(grounder: fn _, _, _ -> raise "should not be called" end)

      assert is_nil(ctx.grounding)
      assert is_nil(ctx.error)
    end

    test "handles grounder error gracefully" do
      grounder = fn _answer, _chunks, _opts ->
        {:error, :model_failed}
      end

      ctx =
        %Context{
          question: "test",
          answer: "test answer",
          context_used: [%{id: 1, text: "context"}]
        }
        |> Agent.ground(grounder: grounder)

      assert is_nil(ctx.grounding)
      assert is_nil(ctx.error)
    end

    test "handles nil context_used" do
      grounder = fn _answer, chunks, _opts ->
        assert chunks == []
        {:ok, %Result{score: 1.0, hallucinated_spans: [], token_labels: []}}
      end

      ctx =
        %Context{
          question: "test",
          answer: "test answer",
          context_used: nil
        }
        |> Agent.ground(grounder: grounder)

      assert ctx.grounding.score == 1.0
    end

    test "emits telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:arcana, :agent, :ground, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      grounder = fn _answer, _chunks, _opts ->
        {:ok,
         %Result{
           score: 0.9,
           hallucinated_spans: [%{text: "x", start: 0, end: 1, score: 0.5}],
           token_labels: []
         }}
      end

      %Context{
        question: "test",
        answer: "test answer",
        context_used: [%{id: 1, text: "context"}]
      }
      |> Agent.ground(grounder: grounder)

      assert_receive {:telemetry, [:arcana, :agent, :ground, :stop], _, stop_meta}
      assert stop_meta.score == 0.9
      assert stop_meta.hallucinated_span_count == 1
      assert stop_meta.faithful_span_count == 0

      :telemetry.detach(ref)
    end
  end
end

defmodule Arcana.Agent.GroundPipelineTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Grounding.Result

  describe "pipeline integration" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language.",
          repo: Arcana.TestRepo,
          collection: "test-ground"
        )

      :ok
    end

    test "full pipeline: search -> answer -> ground" do
      grounder = fn answer, chunks, _opts ->
        assert is_binary(answer)
        assert length(chunks) > 0
        {:ok, %Result{score: 0.95, hallucinated_spans: [], token_labels: []}}
      end

      llm = fn _prompt -> {:ok, "Elixir is a functional language on BEAM."} end

      ctx =
        Agent.new("What is Elixir?",
          repo: Arcana.TestRepo,
          llm: llm,
          graph: false
        )
        |> Agent.search(collection: "test-ground")
        |> Agent.answer()
        |> Agent.ground(grounder: grounder)

      assert ctx.answer == "Elixir is a functional language on BEAM."
      assert ctx.grounding.score == 0.95
      assert is_nil(ctx.error)
    end
  end
end
