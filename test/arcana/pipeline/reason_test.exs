defmodule Arcana.Pipeline.ReasonTest do
  use Arcana.DataCase, async: true

  alias Arcana.Pipeline
  alias Arcana.Pipeline.Context

  # Asks for one follow-up search, then accepts. Anything that isn't the
  # sufficiency prompt gets a throwaway answer.
  defp insufficient_then_sufficient_llm do
    call_count = :counters.new(1, [:atomics])

    fn prompt ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)

      cond do
        count == 0 and prompt =~ "sufficient" ->
          {:ok,
           ~s({"sufficient": false, "missing": "concurrency model", "follow_up_query": "Elixir concurrency actors"})}

        prompt =~ "sufficient" ->
          {:ok, ~s({"sufficient": true, "reasoning": "Now has concurrency info"})}

        true ->
          {:ok, "response"}
      end
    end
  end

  # Says "insufficient" once per follow-up query, in order, then accepts.
  # The queries have to differ: reason/2 stops as soon as a follow-up
  # repeats one that queries_tried already holds.
  defp insufficient_llm(follow_ups) do
    call_count = :counters.new(1, [:atomics])

    fn prompt ->
      if prompt =~ "sufficient" do
        index = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case Enum.at(follow_ups, index) do
          nil ->
            {:ok, ~s({"sufficient": true, "reasoning": "good enough"})}

          query ->
            {:ok,
             JSON.encode!(%{
               "sufficient" => false,
               "missing" => "more detail",
               "follow_up_query" => query
             })}
        end
      else
        {:ok, "response"}
      end
    end
  end

  defp searched_collections(acc \\ []) do
    receive do
      {:searched_collection, collection} -> searched_collections([collection | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "reason/2" do
    test "accepts results when LLM says sufficient" do
      llm = fn prompt ->
        assert prompt =~ "What is Elixir"
        {:ok, ~s({"sufficient": true, "reasoning": "Results contain relevant info"})}
      end

      ctx = %Context{
        question: "What is Elixir?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "What is Elixir?",
            collection: "default",
            chunks: [%{id: "1", text: "Elixir is functional", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["What is Elixir?"])
      }

      ctx = Pipeline.reason(ctx)

      # Should not add more queries
      assert MapSet.size(ctx.queries_tried) == 1
      assert ctx.reason_iterations == 0
    end

    test "searches again when LLM says insufficient" do
      call_count = :counters.new(1, [:atomics])

      llm = fn prompt ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        cond do
          count == 0 and prompt =~ "sufficient" ->
            {:ok,
             ~s({"sufficient": false, "missing": "concurrency model", "follow_up_query": "Elixir concurrency actors"})}

          count == 1 and prompt =~ "sufficient" ->
            {:ok, ~s({"sufficient": true, "reasoning": "Now has concurrency info"})}

          true ->
            {:ok, "response"}
        end
      end

      # Ingest some test content
      {:ok, _} =
        Arcana.ingest("Elixir uses actors for concurrency.",
          repo: Arcana.TestRepo,
          collection: "reason-test"
        )

      ctx = %Context{
        question: "How does Elixir handle concurrency?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "How does Elixir handle concurrency?",
            collection: "reason-test",
            chunks: [%{id: "1", text: "Elixir is functional", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["How does Elixir handle concurrency?"])
      }

      ctx = Pipeline.reason(ctx)

      # Should have searched again
      assert ctx.reason_iterations == 1
      assert MapSet.member?(ctx.queries_tried, "Elixir concurrency actors")
    end

    test "respects max_iterations limit" do
      llm = fn prompt ->
        if prompt =~ "sufficient" do
          {:ok,
           ~s({"sufficient": false, "missing": "more info", "follow_up_query": "query #{System.unique_integer([:positive])}"})}
        else
          {:ok, "response"}
        end
      end

      {:ok, _} =
        Arcana.ingest("Some content for max iterations test.",
          repo: Arcana.TestRepo,
          collection: "max-iter-test"
        )

      ctx = %Context{
        question: "test question",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{
            question: "test",
            collection: "max-iter-test",
            chunks: [%{id: "1", text: "content", score: 0.9}]
          }
        ],
        queries_tried: MapSet.new(["test question"])
      }

      ctx = Pipeline.reason(ctx, max_iterations: 2)

      # Should stop after 2 iterations even if still insufficient
      assert ctx.reason_iterations == 2
    end

    test "prevents duplicate queries" do
      llm = fn prompt ->
        if prompt =~ "sufficient" do
          # Always suggest the same follow-up query
          {:ok, ~s({"sufficient": false, "missing": "more", "follow_up_query": "same query"})}
        else
          {:ok, "response"}
        end
      end

      {:ok, _} =
        Arcana.ingest("Content for duplicate test.",
          repo: Arcana.TestRepo,
          collection: "dup-test"
        )

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "dup-test", chunks: [%{id: "1", text: "x", score: 0.9}]}
        ],
        queries_tried: MapSet.new(["test", "same query"])
      }

      ctx = Pipeline.reason(ctx, max_iterations: 3)

      # Should stop because follow_up_query was already tried
      assert ctx.reason_iterations == 0
    end

    test "defaults to accepting on LLM error" do
      llm = fn _prompt -> {:error, :api_error} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "default", chunks: []}
        ],
        queries_tried: MapSet.new(["test"])
      }

      ctx = Pipeline.reason(ctx)

      # Should proceed without error
      assert is_nil(ctx.error)
      assert ctx.reason_iterations == 0
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach_many(
        ref,
        [
          [:arcana, :pipeline, :reason, :start],
          [:arcana, :pipeline, :reason, :stop]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      llm = fn _prompt -> {:ok, ~s({"sufficient": true, "reasoning": "ok"})} end

      ctx = %Context{
        question: "test",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [
          %{question: "test", collection: "default", chunks: []}
        ],
        queries_tried: MapSet.new(["test"])
      }

      Pipeline.reason(ctx)

      assert_receive {:telemetry, [:arcana, :pipeline, :reason, :start], _, %{question: "test"}}
      assert_receive {:telemetry, [:arcana, :pipeline, :reason, :stop], _, %{iterations: 0}}

      :telemetry.detach(ref)
    end

    test "initializes queries_tried if not set" do
      llm = fn _prompt -> {:ok, ~s({"sufficient": true})} end

      ctx = %Context{
        question: "my question",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        results: [%{question: "test", collection: "default", chunks: []}],
        queries_tried: nil
      }

      ctx = Pipeline.reason(ctx)

      assert MapSet.member?(ctx.queries_tried, "my question")
    end

    # A caller that scopes retrieval by handing search/2 a tenant searcher
    # would silently get the default (unscoped) searcher back for the
    # follow-up searches if reason/2 didn't inherit it, which hands the
    # caller chunks from outside the tenant.
    test "inherits the searcher from search/2 without repeating the option" do
      test_pid = self()

      searcher = fn question, _collection, _opts ->
        send(test_pid, {:searched, question})
        {:ok, [%{id: "1", text: "scoped chunk", score: 0.9}]}
      end

      ctx =
        "How does Elixir handle concurrency?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: insufficient_then_sufficient_llm())
        |> Pipeline.search(searcher: searcher, collection: "inherit-searcher-test")
        |> Pipeline.reason()

      assert ctx.reason_iterations == 1
      assert_received {:searched, "How does Elixir handle concurrency?"}
      assert_received {:searched, "Elixir concurrency actors"}
    end

    test "inherits arbitrary backend and auth options from search/2" do
      test_pid = self()

      searcher = fn question, _collection, opts ->
        send(test_pid, {:searched_with_opts, question, opts})
        {:ok, [%{id: question, text: "scoped chunk", score: 0.9}]}
      end

      ctx =
        "How does Elixir handle concurrency?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: insufficient_then_sufficient_llm())
        |> Pipeline.search(
          searcher: searcher,
          collection: "tenant-a",
          tenant_id: "tenant-a",
          auth_token: "signed-token",
          backend_timeout: 321
        )
        |> Pipeline.reason()

      assert ctx.reason_iterations == 1

      assert_received {:searched_with_opts, "Elixir concurrency actors", opts}
      assert opts[:tenant_id] == "tenant-a"
      assert opts[:auth_token] == "signed-token"
      assert opts[:backend_timeout] == 321
      assert opts[:repo] == Arcana.TestRepo
      assert opts[:limit] == 5
      assert opts[:threshold] == 0.5
    end

    test "an explicit searcher on reason/2 beats the inherited one" do
      test_pid = self()

      search_searcher = fn _question, _collection, _opts ->
        {:ok, [%{id: "1", text: "from search", score: 0.9}]}
      end

      reason_searcher = fn question, _collection, opts ->
        send(test_pid, {:reason_searched, question, opts})
        {:ok, [%{id: "2", text: "from reason", score: 0.9}]}
      end

      ctx =
        "How does Elixir handle concurrency?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: insufficient_then_sufficient_llm())
        |> Pipeline.search(
          searcher: search_searcher,
          collection: "explicit-searcher-test",
          original_backend_token: "do-not-forward"
        )
        |> Pipeline.reason(
          searcher: reason_searcher,
          searcher_opts: [replacement_backend_token: "forward-this"]
        )

      assert ctx.reason_iterations == 1

      assert_received {:reason_searched, "Elixir concurrency actors", opts}
      assert opts[:replacement_backend_token] == "forward-this"
      refute Keyword.has_key?(opts, :original_backend_token)
    end

    # search/2 resolved ["tenant-a"], so every follow-up has to stay there.
    # Before search/2 recorded its collections, the first follow-up rode
    # hd(ctx.results).collection and the second — after merge_results
    # dropped the dry result — fell through to "default". That reads as a
    # narrow scope but isn't: strict_collections defaults to false, so an
    # unknown name resolves to no collection filter at all, i.e. the whole
    # corpus for a caller that named one tenant.
    test "follow-up searches stay in the collections search/2 resolved" do
      test_pid = self()

      searcher = fn _question, collection, _opts ->
        send(test_pid, {:searched_collection, collection})
        {:ok, []}
      end

      llm = insufficient_llm(["tenant policy details", "tenant policy exceptions"])

      ctx =
        "What is the tenant policy?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: llm)
        |> Pipeline.search(searcher: searcher, collection: ["tenant-a"])
        |> Pipeline.reason()

      assert ctx.reason_iterations == 2
      assert searched_collections() == ["tenant-a", "tenant-a", "tenant-a"]
    end

    # Same leak against a real repo and the default searcher: an empty
    # collection makes every follow-up run dry, which used to hand the last
    # one an unscoped search over the whole corpus.
    test "follow-up searches never return chunks outside the caller's collection" do
      {:ok, _} = Arcana.Collection.get_or_create("probe-tenant-a", Arcana.TestRepo)

      other_tenant_text = "Zorblax quantum flux capacitor blueprint"

      {:ok, _} =
        Arcana.ingest(other_tenant_text, repo: Arcana.TestRepo, collection: "probe-tenant-b")

      llm = insufficient_llm(["wumpus grommet sprocket", other_tenant_text])

      ctx =
        "What is the Zorblax blueprint?"
        |> Pipeline.new(repo: Arcana.TestRepo, llm: llm, threshold: 0.1)
        |> Pipeline.search(collection: ["probe-tenant-a"])
        |> Pipeline.reason()

      assert Enum.all?(ctx.results, &(&1.collection == "probe-tenant-a"))

      chunks = Enum.flat_map(ctx.results, & &1.chunks)
      refute Enum.any?(chunks, &(&1.text =~ "Zorblax"))
    end

    test "skips reasoning when skip_retrieval is true" do
      # LLM should not be called since we're skipping retrieval
      llm = fn _prompt -> raise "LLM should not be called" end

      ctx = %Context{
        question: "What is 2 + 2?",
        repo: Arcana.TestRepo,
        llm: llm,
        limit: 5,
        threshold: 0.5,
        skip_retrieval: true,
        results: [],
        queries_tried: nil
      }

      ctx = Pipeline.reason(ctx)

      # Should not have done any reasoning
      assert ctx.reason_iterations == 0 or is_nil(ctx.reason_iterations)
    end
  end
end
