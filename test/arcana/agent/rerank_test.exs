defmodule Arcana.Agent.RerankTest do
  use Arcana.DataCase, async: true

  alias Arcana.Agent
  alias Arcana.Agent.Context

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
      llm = fn prompt ->
        cond do
          prompt =~ "functional programming" ->
            {:ok, ~s({"score": 9, "reasoning": "highly relevant"})}

          prompt =~ "weather" ->
            {:ok, ~s({"score": 2, "reasoning": "not relevant"})}

          prompt =~ "BEAM virtual machine" ->
            {:ok, ~s({"score": 8, "reasoning": "relevant context"})}

          prompt =~ "Rate how relevant" ->
            {:ok, ~s({"score": 5, "reasoning": "default"})}

          true ->
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
        |> Agent.search()
        |> Agent.rerank(threshold: 7)

      # Should filter out the weather chunk
      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      refute Enum.any?(all_chunks, &(&1.text =~ "weather"))
      assert Enum.any?(all_chunks, &(&1.text =~ "functional"))
    end

    test "re-sorts chunks by score descending" do
      # LLM gives higher score to BEAM chunk
      llm = fn prompt ->
        cond do
          prompt =~ "BEAM" ->
            {:ok, ~s({"score": 10, "reasoning": "best match"})}

          prompt =~ "functional" ->
            {:ok, ~s({"score": 8, "reasoning": "good match"})}

          prompt =~ "Rate how relevant" ->
            {:ok, ~s({"score": 9, "reasoning": "default high"})}

          true ->
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
        |> Agent.search()
        |> Agent.rerank(threshold: 7)

      all_chunks = Enum.flat_map(ctx.results, & &1.chunks)
      # First chunk should be the BEAM one (highest score)
      assert hd(all_chunks).text =~ "BEAM"
    end

    test "uses default LLM reranker when no reranker specified" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 8, "reasoning": "relevant"})}
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
        |> Agent.search()
        |> Agent.rerank()

      # Should have reranked results
      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker module" do
      defmodule TestReranker do
        @behaviour Arcana.Agent.Reranker

        @impl Arcana.Agent.Reranker
        def rerank(_question, chunks, _opts) do
          # Just reverse the chunks as a simple test
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
        |> Agent.search()
        |> Agent.rerank(reranker: TestReranker)

      # Reranker was called (chunks are reversed)
      refute Enum.empty?(ctx.results)
    end

    test "accepts custom reranker function" do
      llm = fn _prompt -> {:ok, "response"} end

      custom_reranker = fn _question, chunks, _opts ->
        # Filter to only chunks containing "Elixir"
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
        |> Agent.search()
        |> Agent.rerank(reranker: custom_reranker)

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

      result = Agent.rerank(ctx)

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

      result = Agent.rerank(ctx)

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
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 8, "reasoning": "relevant"})}
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
      |> Agent.search()
      |> Agent.rerank()

      assert_receive {:telemetry, [:arcana, :agent, :rerank, :stop], _, stop_meta}
      assert is_integer(stop_meta.chunks_before)
      assert is_integer(stop_meta.chunks_after)

      :telemetry.detach(ref)
    end

    test "stores rerank scores in context" do
      llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 9, "reasoning": "good"})}
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
        |> Agent.search()
        |> Agent.rerank()

      assert is_map(ctx.rerank_scores)
      refute Enum.empty?(ctx.rerank_scores)
    end

    test "accepts custom llm option" do
      default_llm = fn _prompt -> raise "default LLM should not be called" end

      custom_llm = fn prompt ->
        if prompt =~ "Rate how relevant" do
          {:ok, ~s({"score": 9, "reasoning": "custom llm scored"})}
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
        |> Agent.search()
        |> Agent.rerank(llm: custom_llm)

      # Rerank should succeed using custom LLM
      refute Enum.empty?(ctx.results)
      assert is_map(ctx.rerank_scores)
    end
  end
end
