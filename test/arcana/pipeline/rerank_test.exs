defmodule Arcana.Pipeline.RerankTest do
  use Arcana.DataCase, async: true

  alias Arcana.Pipeline
  alias Arcana.Pipeline.Context

  # Parses a batched rerank prompt and assigns scores based on passage content.
  # Returns a batched JSON response like {"1": 9, "2": 2, "3": 8}.
  defp batch_rerank_response(prompt, score_rules) do
    scores =
      Regex.scan(~r/\[(\d+)\] (.+)/, prompt)
      |> Map.new(fn [_, id, text] ->
        score =
          Enum.find_value(score_rules, 5, fn {keyword, score} ->
            if String.contains?(text, keyword), do: score
          end)

        {id, score}
      end)

    {:ok, JSON.encode!(scores)}
  end

  describe "rerank/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest("Elixir is a functional programming language.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      {:ok, _doc} =
        Arcana.ingest("The weather is sunny today.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      {:ok, _doc} =
        Arcana.ingest("Elixir runs on the BEAM virtual machine.",
          repo: Arcana.TestRepo,
          collection: "test-rerank"
        )

      :ok
    end

    test "reranks and filters chunks by score threshold" do
      score_rules = [
        {"functional programming", 9},
        {"weather", 2},
        {"sunny", 2},
        {"BEAM virtual machine", 8}
      ]

      llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          batch_rerank_response(prompt, score_rules)
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "What is Elixir?",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank(threshold: 7)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      refute Enum.any?(all_chunks, &(&1.text =~ "weather"))
      assert Enum.any?(all_chunks, &(&1.text =~ "functional"))
    end

    test "re-sorts chunks by score descending" do
      score_rules = [
        {"BEAM", 10},
        {"functional", 8},
        {"weather", 9},
        {"sunny", 9}
      ]

      llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          batch_rerank_response(prompt, score_rules)
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "BEAM VM",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank(threshold: 7)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      assert hd(all_chunks).text =~ "BEAM"
    end

    test "uses default LLM reranker when no reranker specified" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          scores =
            Regex.scan(~r/\[(\d+)\]/, prompt)
            |> Map.new(fn [_, id] -> {id, 8} end)

          {:ok, JSON.encode!(scores)}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank()

      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker module" do
      defmodule TestReranker do
        @behaviour Arcana.Pipeline.Reranker

        @impl Arcana.Pipeline.Reranker
        def rerank(_question, chunks, _opts) do
          {:ok, Enum.reverse(chunks)}
        end
      end

      llm = fn _prompt -> {:ok, "response"} end

      ctx =
        %Context{
          question: "Elixir programming",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank(reranker: TestReranker)

      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker function" do
      llm = fn _prompt -> {:ok, "response"} end

      custom_reranker = fn _question, chunks, _opts ->
        filtered = Enum.filter(chunks, &(&1.text =~ "Elixir"))
        {:ok, filtered}
      end

      ctx =
        %Context{
          question: "programming language",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank(reranker: custom_reranker)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      assert Enum.all?(all_chunks, &(&1.text =~ "Elixir"))
    end

    test "skips if context has error" do
      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: fn _ -> {:ok, "response"} end,
        error: :previous_error,
        results: []
      }

      result = Pipeline.rerank(ctx)

      assert result.error == :previous_error
    end

    test "handles empty results gracefully" do
      llm = fn _prompt -> {:ok, "response"} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        results: []
      }

      result = Pipeline.rerank(ctx)

      assert result.results == []
      assert is_nil(result.error)
    end

    test "emits telemetry events" do
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        ref,
        [:arcana, :agent, :rerank, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          scores =
            Regex.scan(~r/\[(\d+)\]/, prompt)
            |> Map.new(fn [_, id] -> {id, 8} end)

          {:ok, JSON.encode!(scores)}
        else
          {:ok, "response"}
        end
      end

      %Context{
        question: "Elixir",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 10,
        threshold: 0.0,
        collections: ["test-rerank"]
      }
      |> Pipeline.search()
      |> Pipeline.rerank()

      assert_receive {:telemetry, [:arcana, :agent, :rerank, :stop], _, stop_meta}
      assert is_integer(stop_meta.original)
      assert is_integer(stop_meta.kept)

      :telemetry.detach(ref)
    end

    test "stores rerank scores in context" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          scores =
            Regex.scan(~r/\[(\d+)\]/, prompt)
            |> Map.new(fn [_, id] -> {id, 9} end)

          {:ok, JSON.encode!(scores)}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank()

      assert is_map(ctx.rerank_scores)
      refute Enum.empty?(ctx.rerank_scores)
    end

    test "accepts custom llm option" do
      default_llm = fn _prompt -> raise "default LLM should not be called" end

      custom_llm = fn prompt ->
        if prompt =~ "Rate how relevant each passage" do
          scores =
            Regex.scan(~r/\[(\d+)\]/, prompt)
            |> Map.new(fn [_, id] -> {id, 9} end)

          {:ok, JSON.encode!(scores)}
        else
          {:ok, "response"}
        end
      end

      ctx =
        %Context{
          question: "Elixir",
          repo: Arcana.TestRepo,
          llm: default_llm,
          limit: 10,
          threshold: 0.0,
          collections: ["test-rerank"]
        }
        |> Pipeline.search()
        |> Pipeline.rerank(llm: custom_llm)

      refute Enum.empty?(ctx.results)
      assert is_map(ctx.rerank_scores)
    end

    test "skips reranking when skip_retrieval is true" do
      llm = fn _prompt -> raise "LLM should not be called" end

      ctx = %Context{
        question: "What is 2 + 2?",
        repo: Arcana.TestRepo,
        llm: llm,
        skip_retrieval: true,
        results: []
      }

      ctx = Pipeline.rerank(ctx)

      assert ctx.results == []
      assert is_nil(ctx.error)
    end
  end
end
