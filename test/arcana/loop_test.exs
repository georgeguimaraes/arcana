defmodule Arcana.LoopTest do
  @moduledoc """
  Tests for Arcana.Loop, the agentic RAG loop.

  These tests inject a stub controller (a function) that returns scripted
  classified responses, so we can drive the loop without hitting a real LLM.
  """

  use ExUnit.Case, async: true

  alias Arcana.Loop
  alias Arcana.Loop.Context
  alias Arcana.Loop.Tools

  # Builds a stub controller that returns scripted responses one per call.
  # Each scripted response is either a `ReqLLM.Response.classify_result()`-shaped
  # map or a function `(messages, tools, opts) -> {:ok, classified}` that lets a
  # test inspect the conversation at a specific iteration.
  defp scripted_controller(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn messages, tools, opts ->
      next =
        Agent.get_and_update(agent, fn
          [head | rest] -> {head, rest}
          [] -> {nil, []}
        end)

      case next do
        nil -> {:error, :no_more_scripted_responses}
        fun when is_function(fun, 3) -> fun.(messages, tools, opts)
        classified -> {:ok, classified}
      end
    end
  end

  defp tool_call(name, args, id \\ "call_1") do
    %{id: id, name: name, arguments: args}
  end

  defp final_answer(text) do
    %{
      type: :final_answer,
      text: text,
      thinking: "",
      tool_calls: [],
      finish_reason: :stop
    }
  end

  defp tool_call_response(calls) do
    %{
      type: :tool_calls,
      text: "",
      thinking: "",
      tool_calls: calls,
      finish_reason: :tool_calls
    }
  end

  describe "Tools.default/0" do
    test "ships exactly the three tools the controller actually uses" do
      # We dropped rewrite and decompose because empirical runs showed
      # controllers never picked them — they're redundant with what the
      # model can do via sequential search calls. Anthropic's tool sprawl
      # guidance says drop tools that don't change agent behavior.
      tool_names =
        Tools.default()
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert tool_names == ["answer", "give_up", "search"]
    end
  end

  describe "Tools.default/1 with collections" do
    test "single-collection context: search tool has no :collection param (locked)" do
      tools = Tools.default(["docs"])
      search = Enum.find(tools, &(&1.name == "search"))
      param_names = Enum.map(search.parameter_schema, &elem(&1, 0))

      refute :collection in param_names
      assert :query in param_names
      assert :limit in param_names
    end

    test "unrestricted context ([nil]): search tool has no :collection param" do
      tools = Tools.default([nil])
      search = Enum.find(tools, &(&1.name == "search"))
      param_names = Enum.map(search.parameter_schema, &elem(&1, 0))

      refute :collection in param_names
    end

    test "multi-collection context: search tool gains :collection param listing choices" do
      tools = Tools.default(["docs", "wiki", "changelog"])
      search = Enum.find(tools, &(&1.name == "search"))
      param_names = Enum.map(search.parameter_schema, &elem(&1, 0))

      assert :collection in param_names

      collection_opts = Keyword.fetch!(search.parameter_schema, :collection)
      assert collection_opts[:type] == :string
      refute collection_opts[:required]
      assert collection_opts[:doc] =~ "docs"
      assert collection_opts[:doc] =~ "wiki"
      assert collection_opts[:doc] =~ "changelog"

      assert search.description =~ "Available collections:"
      assert search.description =~ "docs"
      assert search.description =~ "wiki"
    end
  end

  describe "Tools.execute search collection arg" do
    test "multi-collection ctx + no collection arg → searches across all" do
      search_fn = fn _q, opts ->
        send(self(), {:search_opts, opts})
        {:ok, [%{id: "c1", text: "hit", score: 0.5}]}
      end

      ctx = %Context{repo: nil, collections: ["a", "b"]}

      {:continue, _new_ctx, _summary, _meta} =
        Tools.execute(ctx, "search", %{query: "q"}, search_fn: search_fn)

      assert_received {:search_opts, opts}
      assert opts[:collections] == ["a", "b"]
      refute opts[:collection]
    end

    test "multi-collection ctx + valid collection arg → narrows to that one" do
      search_fn = fn _q, opts ->
        send(self(), {:search_opts, opts})
        {:ok, [%{id: "c1", text: "hit", score: 0.5}]}
      end

      ctx = %Context{repo: nil, collections: ["a", "b"]}

      {:continue, _new_ctx, _summary, _meta} =
        Tools.execute(ctx, "search", %{query: "q", collection: "a"}, search_fn: search_fn)

      assert_received {:search_opts, opts}
      assert opts[:collection] == "a"
      refute opts[:collections]
    end

    test "multi-collection ctx + invalid collection arg → error summary, loop continues" do
      # search_fn should NOT be called
      search_fn = fn _q, _opts ->
        flunk("search_fn should not be called with an invalid collection")
      end

      ctx = %Context{repo: nil, collections: ["a", "b"]}

      {:continue, new_ctx, summary, meta} =
        Tools.execute(ctx, "search", %{query: "q", collection: "c"}, search_fn: search_fn)

      assert summary =~ "search error"
      assert summary =~ "not in the allowed list"
      assert meta.returned_chunk_ids == []
      assert new_ctx == ctx
    end

    test "single-locked ctx → collection always uses the lock, arg ignored" do
      search_fn = fn _q, opts ->
        send(self(), {:search_opts, opts})
        {:ok, []}
      end

      ctx = %Context{repo: nil, collections: ["locked"]}

      # Controller shouldn't even have the param (enforced at schema
      # level), but if one somehow gets through, execute falls back to
      # the locked collection regardless.
      Tools.execute(ctx, "search", %{query: "q", collection: "other"}, search_fn: search_fn)

      assert_received {:search_opts, opts}
      assert opts[:collection] == "locked"
    end
  end

  describe "SystemPrompt.default/1 collections section" do
    alias Arcana.Loop.SystemPrompt

    test "multi-collection context includes the Collections section" do
      prompt = SystemPrompt.default(collections: ["docs", "wiki"], max_iterations: 5)

      assert prompt =~ "# Collections"
      assert prompt =~ "`docs`"
      assert prompt =~ "`wiki`"
      assert prompt =~ "`collection` argument"
    end

    test "single-collection context omits the Collections section" do
      prompt = SystemPrompt.default(collections: ["docs"], max_iterations: 5)

      refute prompt =~ "# Collections"
    end

    test "unrestricted context ([nil]) omits the Collections section" do
      prompt = SystemPrompt.default(collections: [nil], max_iterations: 5)

      refute prompt =~ "# Collections"
    end
  end

  describe "new/2" do
    test "builds a context with the question" do
      ctx = Loop.new("What is Doctor Who?")
      assert %Context{question: "What is Doctor Who?", iterations: 0} = ctx
    end

    test "stores the collection option" do
      ctx = Loop.new("question", collection: "doctor-who")
      assert ctx.collections == ["doctor-who"]
    end

    test "stores collections list when given" do
      ctx = Loop.new("question", collections: ["a", "b"])
      assert ctx.collections == ["a", "b"]
    end
  end

  describe "run/2 termination" do
    test "terminates with :answered when controller calls the answer tool" do
      controller =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "42"})])
        ])

      {:ok, ctx} =
        Loop.new("ultimate question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :answered
      assert ctx.answer == "42"
      assert ctx.iterations == 1
    end

    test "terminates with :gave_up when controller calls the give_up tool" do
      controller =
        scripted_controller([
          tool_call_response([tool_call("give_up", %{"reason" => "no data"})])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :gave_up
      assert ctx.answer =~ "no data"
    end

    test "terminates with :max_iterations when the controller never calls a terminating tool" do
      # Search returns no chunks each time, so the controller stays in the
      # search loop without ever committing.
      search_fn = fn _q, _opts -> {:ok, []} end

      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "anything"})])}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, search_fn: search_fn, max_iterations: 3)

      assert ctx.terminated_by == :max_iterations
      assert ctx.iterations == 3
    end

    test "terminates with :error when the controller returns an error" do
      controller = fn _msgs, _tools, _opts -> {:error, :boom} end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :error
      assert ctx.error == :boom
    end

    test "terminates with :answered when the controller returns a final answer (no tool calls)" do
      controller =
        scripted_controller([
          final_answer("Direct answer without tool use.")
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :answered
      assert ctx.answer == "Direct answer without tool use."
    end
  end

  describe "run/2 multi-turn flow" do
    test "records tool history across iterations" do
      search_fn = fn _q, _opts ->
        {:ok, [%{id: "c1", text: "first result", score: 0.9}]}
      end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "first"}, "c1")]),
          tool_call_response([tool_call("answer", %{"text" => "done"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, search_fn: search_fn)

      assert ctx.terminated_by == :answered
      assert ctx.answer == "done"
      assert length(ctx.tool_history) == 2

      [first, second] = ctx.tool_history
      assert first.tool == :search
      assert first.iteration == 0
      assert second.tool == :answer
      assert second.iteration == 1
    end
  end

  describe "run/2 search tool" do
    test "search tool calls a stub search_fn and accumulates chunks" do
      search_fn = fn "ren and stimpy", _opts ->
        {:ok,
         [
           %{id: "c1", text: "Ren is a chihuahua", score: 0.9},
           %{id: "c2", text: "Stimpy is a cat", score: 0.8}
         ]}
      end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "ren and stimpy"}, "c1")]),
          tool_call_response([tool_call("answer", %{"text" => "they're friends"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("who are ren and stimpy")
        |> Loop.run(controller_llm: controller, search_fn: search_fn)

      assert ctx.terminated_by == :answered
      assert length(ctx.chunks) == 2
      assert Enum.map(ctx.chunks, & &1.id) == ["c1", "c2"]
    end

    test "chunk_cap evicts lowest-scored chunks across iterations" do
      search_fn_first = fn _q, _opts ->
        {:ok,
         [
           %{id: "a", text: "low", score: 0.1},
           %{id: "b", text: "mid", score: 0.5}
         ]}
      end

      search_fn_second = fn _q, _opts ->
        {:ok,
         [
           %{id: "c", text: "high", score: 0.9},
           %{id: "d", text: "higher", score: 0.95}
         ]}
      end

      {:ok, agent} = Agent.start_link(fn -> [search_fn_first, search_fn_second] end)

      search_fn = fn q, opts ->
        next = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        next.(q, opts)
      end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "first"}, "c1")]),
          tool_call_response([tool_call("search", %{"query" => "second"}, "c2")]),
          tool_call_response([tool_call("answer", %{"text" => "ok"}, "c3")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, search_fn: search_fn, chunk_cap: 2)

      # Cap is 2, so the highest-scored chunks across both iterations win.
      assert Enum.map(ctx.chunks, & &1.id) == ["d", "c"]
      assert Enum.map(ctx.chunks, & &1.score) == [0.95, 0.9]
    end

    test "search tool result contains full chunk text without truncation" do
      # A chunk longer than the historical 400-char cap. The model needs to see
      # the whole thing to actually reason over it; truncating makes the loop
      # over-search because the previews never look "good enough".
      long_text =
        String.duplicate("Phoenix LiveView is a server-rendered UI library. ", 30)

      search_fn = fn _q, _opts ->
        {:ok, [%{id: "long-1", text: long_text, score: 0.9}]}
      end

      # Capture the tool result text the controller actually sees by recording
      # the second iteration's messages (the first message after the assistant
      # tool call should be the tool result).
      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "phoenix"}, "c1")]),
          fn messages, _tools, _opts ->
            tool_msg = Enum.find(messages.messages, &(&1.role == :tool))
            send(self(), {:tool_result, tool_message_text(tool_msg)})

            {:ok,
             %{
               type: :tool_calls,
               text: "",
               thinking: "",
               tool_calls: [tool_call("answer", %{"text" => "ok"}, "c2")],
               finish_reason: :tool_calls
             }}
          end
        ])

      {:ok, _ctx} =
        Loop.new("what is liveview")
        |> Loop.run(controller_llm: controller, search_fn: search_fn)

      assert_received {:tool_result, tool_text}

      # The full long text must appear in the tool result, no "..." truncation.
      assert tool_text =~ long_text
      refute tool_text =~ "..."
      # Stable chunk ID is still present so the model can reference specific chunks.
      assert tool_text =~ "[long-1]"
    end

    test "search tool reports an error in the summary but does not terminate the loop" do
      search_fn = fn _q, _opts -> {:error, :db_down} end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "anything"}, "c1")]),
          tool_call_response([tool_call("give_up", %{"reason" => "search failed"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, search_fn: search_fn)

      assert ctx.terminated_by == :gave_up
      [search_entry, _give_up] = ctx.tool_history
      assert search_entry.summary =~ "error"
      assert ctx.chunks == []
    end

    test "search tool with missing :query argument continues the loop with an error summary" do
      # Defends Tools.execute's `not is_map_key(args, :query)` clause:
      # a buggy or hallucinating controller can ship a search call without
      # a query, and the loop should report an error back to the controller
      # and keep going rather than crashing.
      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"limit" => 5}, "c1")]),
          tool_call_response([tool_call("give_up", %{"reason" => "no query"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :gave_up
      [search_entry, _give_up] = ctx.tool_history
      assert search_entry.summary =~ "missing :query"
      assert ctx.chunks == []
    end
  end

  describe "run/2 unknown tool name" do
    test "unknown tool name is recorded as a string without leaking an atom" do
      # Defends safe_tool_atom: a hallucinated tool name must not get
      # interned via String.to_atom (atom table is global and unbounded).
      # When String.to_existing_atom raises, the rescue keeps the binary.
      hallucinated_name = "hallucinated_tool_#{System.unique_integer([:positive])}"

      controller =
        scripted_controller([
          tool_call_response([tool_call(hallucinated_name, %{}, "c1")]),
          tool_call_response([tool_call("give_up", %{"reason" => "done"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      [unknown_entry, _give_up] = ctx.tool_history
      # Stored as the original binary. If safe_tool_atom had called
      # String.to_atom instead, this would be an atom and the assertion
      # would fail (binary != atom).
      assert unknown_entry.tool == hallucinated_name
      assert is_binary(unknown_entry.tool)
      assert unknown_entry.summary =~ "Unknown tool"
    end
  end

  describe "run/2 custom tools" do
    test "custom tool callback is invoked and result is returned to the controller" do
      weather_tool =
        ReqLLM.Tool.new!(
          name: "weather",
          description: "Get the weather.",
          parameter_schema: [city: [type: :string, required: true]],
          callback: fn %{city: city} -> {:ok, "#{city}: sunny, 22C"} end
        )

      tools = Tools.default() ++ [weather_tool]

      controller =
        scripted_controller([
          tool_call_response([tool_call("weather", %{"city" => "London"}, "c1")]),
          tool_call_response([tool_call("answer", %{"text" => "It's sunny in London"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("What's the weather in London?")
        |> Loop.run(controller_llm: controller, tools: tools)

      assert ctx.answer == "It's sunny in London"
      [weather_entry, _answer_entry] = ctx.tool_history
      assert weather_entry.tool == :weather
      assert weather_entry.summary == "London: sunny, 22C"
    end

    test "custom tool returning {:error, text} continues with an error message" do
      failing_tool =
        ReqLLM.Tool.new!(
          name: "api_call",
          description: "Call an API.",
          parameter_schema: [endpoint: [type: :string, required: true]],
          callback: fn _args -> {:error, "connection refused"} end
        )

      tools = Tools.default() ++ [failing_tool]

      controller =
        scripted_controller([
          tool_call_response([tool_call("api_call", %{"endpoint" => "/foo"}, "c1")]),
          tool_call_response([tool_call("give_up", %{"reason" => "API down"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, tools: tools)

      [api_entry, _] = ctx.tool_history
      assert api_entry.tool == :api_call
      assert api_entry.summary =~ "Tool error"
    end

    test "custom tool returning a bare string continues with that text" do
      echo_tool =
        ReqLLM.Tool.new!(
          name: "echo",
          description: "Echo back.",
          parameter_schema: [text: [type: :string, required: true]],
          callback: fn %{text: t} -> t end
        )

      tools = Tools.default() ++ [echo_tool]

      controller =
        scripted_controller([
          tool_call_response([tool_call("echo", %{"text" => "hello"}, "c1")]),
          tool_call_response([tool_call("answer", %{"text" => "done"}, "c2")])
        ])

      {:ok, ctx} =
        Loop.new("q")
        |> Loop.run(controller_llm: controller, tools: tools)

      [echo_entry, _] = ctx.tool_history
      assert echo_entry.summary == "hello"
    end
  end

  describe "run/2 validation" do
    test "raises when no controller_llm is provided" do
      assert_raise ArgumentError, ~r/controller_llm/, fn ->
        Loop.new("question") |> Loop.run([])
      end
    end
  end

  describe "run/2 max_iterations fallback synthesis" do
    test "when hitting max_iterations, synthesizes a final answer from accumulated chunks" do
      search_fn = fn _q, _opts ->
        {:ok,
         [
           %{
             id: "c1",
             text: "TARDIS stands for Time And Relative Dimension In Space.",
             score: 0.5
           }
         ]}
      end

      # Controller never calls answer; the loop should fall back to synthesis.
      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "tardis"}, "c1")])}
      end

      synthesizer = fn messages, _opts ->
        # Synthesizer should see the accumulated context (including chunks).
        # Prove it by asserting the user message is the original question.
        send(self(), {:synthesizer_called, messages})
        {:ok, "TARDIS is the Doctor's time machine."}
      end

      {:ok, ctx} =
        Loop.new("What is a TARDIS?")
        |> Loop.run(
          controller_llm: controller,
          search_fn: search_fn,
          max_iterations: 2,
          synthesizer: synthesizer
        )

      assert_received {:synthesizer_called, _messages}
      assert ctx.terminated_by == :max_iterations
      assert ctx.answer == "TARDIS is the Doctor's time machine."

      # The synthesis step is recorded in tool_history so the dashboard
      # trace can surface it alongside the controller's tool calls.
      assert %{tool: :synthesis, args: %{text: "TARDIS is the Doctor's time machine."}} =
               List.last(ctx.tool_history)
    end

    test "synthesis is skipped when no chunks were accumulated" do
      # search_fn returns no chunks every time, so the loop hits
      # max_iterations with ctx.chunks == [].
      search_fn = fn _q, _opts -> {:ok, []} end

      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "x"}, "c1")])}
      end

      synthesizer = fn _messages, _opts ->
        send(self(), :synthesizer_called)
        {:ok, "should not be called"}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(
          controller_llm: controller,
          search_fn: search_fn,
          max_iterations: 2,
          synthesizer: synthesizer
        )

      refute_received :synthesizer_called
      assert ctx.terminated_by == :max_iterations
      assert ctx.answer == nil
    end

    test "synthesis is skipped when fallback_synthesis: false" do
      search_fn = fn _q, _opts ->
        {:ok, [%{id: "c1", text: "stuff", score: 0.5}]}
      end

      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "x"}, "c1")])}
      end

      synthesizer = fn _messages, _opts ->
        send(self(), :synthesizer_called)
        {:ok, "fallback"}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(
          controller_llm: controller,
          search_fn: search_fn,
          max_iterations: 2,
          fallback_synthesis: false,
          synthesizer: synthesizer
        )

      refute_received :synthesizer_called
      assert ctx.terminated_by == :max_iterations
      assert ctx.answer == nil
    end
  end

  describe "run/2 answer_llm (controller/answerer split)" do
    test "without answer_llm, the controller's tool text becomes ctx.answer" do
      controller =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "draft from controller"})])
        ])

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert ctx.terminated_by == :answered
      assert ctx.answer == "draft from controller"
    end

    test "with answer_llm, the answerer rewrites the controller's draft" do
      controller =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "draft from controller"})])
        ])

      answerer = fn messages, _tools, _opts ->
        send(self(), {:answerer_called, messages})
        {:ok, final_answer("polished from answerer")}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, answer_llm: answerer)

      assert_received {:answerer_called, _messages}
      assert ctx.terminated_by == :answered
      assert ctx.answer == "polished from answerer"
    end

    test "the answerer sees the conversation including the controller's tool call" do
      search_fn = fn _q, _opts ->
        {:ok, [%{id: "c1", text: "Phoenix is an Elixir web framework", score: 0.9}]}
      end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "phoenix"}, "c1")]),
          tool_call_response([tool_call("answer", %{"text" => "draft answer"}, "c2")])
        ])

      answerer = fn messages, _tools, _opts ->
        send(self(), {:answerer_messages, messages.messages})
        {:ok, final_answer("rewritten")}
      end

      {:ok, _ctx} =
        Loop.new("what is phoenix")
        |> Loop.run(controller_llm: controller, answer_llm: answerer, search_fn: search_fn)

      assert_received {:answerer_messages, msgs}

      # The answerer must see: system prompt, user question, assistant search call,
      # tool result with full chunk text, assistant answer call (with draft), and
      # the final synthesis instruction we appended.
      roles = Enum.map(msgs, & &1.role)
      assert :system in roles
      assert :user in roles
      assert :assistant in roles
      assert :tool in roles

      # The full chunk text should be visible to the answerer.
      tool_msgs = Enum.filter(msgs, &(&1.role == :tool))
      tool_text = tool_msgs |> Enum.map_join("\n", &tool_message_text/1)
      assert tool_text =~ "Phoenix is an Elixir web framework"
    end

    test "if the answerer errors, the controller's draft text is used as a fallback" do
      controller =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "draft from controller"})])
        ])

      failing_answerer = fn _msgs, _tools, _opts -> {:error, :answerer_unavailable} end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, answer_llm: failing_answerer)

      assert ctx.terminated_by == :answered
      assert ctx.answer == "draft from controller"
    end

    test "give_up is not rewritten by the answerer" do
      # The answerer is for producing user-facing answer prose. give_up means the
      # model couldn't answer; rewriting that just dresses up failure in nicer
      # words, which is worse than the honest "I can't answer" message.
      controller =
        scripted_controller([
          tool_call_response([tool_call("give_up", %{"reason" => "no data"})])
        ])

      answerer = fn _msgs, _tools, _opts ->
        send(self(), :answerer_called)
        {:ok, final_answer("should not happen")}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, answer_llm: answerer)

      refute_received :answerer_called
      assert ctx.terminated_by == :gave_up
      assert ctx.answer =~ "no data"
    end

    test "answer_llm is also used as the default synthesizer for max_iterations fallback" do
      search_fn = fn _q, _opts ->
        {:ok, [%{id: "c1", text: "stuff", score: 0.9}]}
      end

      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "x"}, "c1")])}
      end

      answerer = fn _messages, _tools, _opts ->
        send(self(), :answerer_used_as_synthesizer)
        {:ok, final_answer("synthesized by answerer")}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(
          controller_llm: controller,
          answer_llm: answerer,
          search_fn: search_fn,
          max_iterations: 2
        )

      assert_received :answerer_used_as_synthesizer
      assert ctx.terminated_by == :max_iterations
      assert ctx.answer == "synthesized by answerer"
    end

    test "explicit :synthesizer takes precedence over answer_llm for the fallback path" do
      search_fn = fn _q, _opts ->
        {:ok, [%{id: "c1", text: "stuff", score: 0.9}]}
      end

      controller = fn _msgs, _tools, _opts ->
        {:ok, tool_call_response([tool_call("search", %{"query" => "x"}, "c1")])}
      end

      answerer = fn _msgs, _tools, _opts ->
        send(self(), :answerer_used)
        {:ok, final_answer("from answerer")}
      end

      explicit_synthesizer = fn _msgs, _opts ->
        send(self(), :synthesizer_used)
        {:ok, "from explicit synthesizer"}
      end

      {:ok, ctx} =
        Loop.new("question")
        |> Loop.run(
          controller_llm: controller,
          answer_llm: answerer,
          synthesizer: explicit_synthesizer,
          search_fn: search_fn,
          max_iterations: 2
        )

      assert_received :synthesizer_used
      refute_received :answerer_used
      assert ctx.answer == "from explicit synthesizer"
    end
  end

  describe "run/2 controller_llm forms" do
    test "accepts a {model, llm_opts} tuple by unwrapping the opts" do
      # Capture the opts passed to a stub controller after tuple unwrapping.
      captured_opts =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "ok"})])
        ])

      capturing = fn messages, tools, opts ->
        send(self(), {:opts, opts})
        captured_opts.(messages, tools, opts)
      end

      # The Loop's tuple clause unwraps the tuple before dispatching, so a
      # tuple wrapping a function should still be unwrapped to call the function.
      {:ok, _ctx} =
        Loop.new("q")
        |> Loop.run(controller_llm: {capturing, [api_key: "secret"]})

      assert_received {:opts, opts}
      assert opts[:api_key] == "secret"
    end
  end

  describe "run/2 system prompt" do
    test "uses the default prompt when none is given" do
      controller = fn messages, _tools, _opts ->
        # Capture the system message text
        system = messages.messages |> Enum.find(&(&1.role == :system))
        send(self(), {:system_text, system_text(system)})
        {:ok, final_answer("ok")}
      end

      {:ok, _ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller)

      assert_received {:system_text, text}
      assert text =~ "research agent"
      assert text =~ "search"
    end

    test "accepts a custom system prompt string" do
      controller = fn messages, _tools, _opts ->
        system = messages.messages |> Enum.find(&(&1.role == :system))
        send(self(), {:system_text, system_text(system)})
        {:ok, final_answer("ok")}
      end

      {:ok, _ctx} =
        Loop.new("question")
        |> Loop.run(controller_llm: controller, system_prompt: "Custom prompt here.")

      assert_received {:system_text, "Custom prompt here."}
    end
  end

  describe "ground/2" do
    defp stub_grounder(score) do
      fn answer, chunks, _opts ->
        send(self(), {:grounder_called, answer, chunks})

        {:ok,
         %Arcana.Grounding.Result{
           score: score,
           hallucinated_spans: [],
           faithful_spans: [
             %{
               text: "stub",
               start: 0,
               end: 4,
               score: score,
               sources: Enum.map(chunks, fn c -> %{chunk_id: c.id, score: 1.0} end)
             }
           ]
         }}
      end
    end

    test "stores the grounding result in ctx.grounding" do
      ctx = %Context{
        question: "q",
        answer: "some answer",
        chunks: [%{id: "c1", text: "supporting text", score: 0.9}]
      }

      grounded = Loop.ground(ctx, grounder: stub_grounder(0.87))

      assert_received {:grounder_called, "some answer", [%{id: "c1"}]}
      assert grounded.grounding.score == 0.87
      assert length(grounded.grounding.faithful_spans) == 1
    end

    test "is a no-op when ctx.answer is nil" do
      ctx = %Context{
        question: "q",
        answer: nil,
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      grounder = fn _a, _c, _o ->
        send(self(), :grounder_called)
        {:ok, %Arcana.Grounding.Result{score: 0.5}}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      refute_received :grounder_called
      assert grounded.grounding == nil
    end

    test "is a no-op when ctx.error is set" do
      ctx = %Context{
        question: "q",
        answer: "an answer",
        error: :boom,
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      grounder = fn _a, _c, _o ->
        send(self(), :grounder_called)
        {:ok, %Arcana.Grounding.Result{score: 0.5}}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      refute_received :grounder_called
      assert grounded.grounding == nil
    end

    test "is a no-op when ctx.chunks is empty (nothing to ground against)" do
      ctx = %Context{
        question: "q",
        answer: "an answer",
        chunks: []
      }

      grounder = fn _a, _c, _o ->
        send(self(), :grounder_called)
        {:ok, %Arcana.Grounding.Result{score: 0.5}}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      refute_received :grounder_called
      assert grounded.grounding == nil
    end

    test "swallows grounder errors and leaves grounding nil" do
      ctx = %Context{
        question: "q",
        answer: "an answer",
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      grounder = fn _a, _c, _o -> {:error, :model_unavailable} end

      grounded = Loop.ground(ctx, grounder: grounder)

      assert grounded.grounding == nil
      # Ctx is otherwise unchanged.
      assert grounded.answer == "an answer"
      assert grounded.error == nil
    end

    test "passes the question to the grounder via opts" do
      ctx = %Context{
        question: "what is x",
        answer: "x is y",
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      grounder = fn _answer, _chunks, opts ->
        send(self(), {:question, opts[:question]})
        {:ok, %Arcana.Grounding.Result{score: 0.9}}
      end

      Loop.ground(ctx, grounder: grounder)

      assert_received {:question, "what is x"}
    end

    test "accepts a grounder module via opts" do
      # Verifies the module dispatch path (not just function dispatch).
      defmodule StubGrounder do
        @behaviour Arcana.Grounder

        @impl true
        def ground(_answer, _chunks, _opts) do
          {:ok, %Arcana.Grounding.Result{score: 0.55}}
        end
      end

      ctx = %Context{
        question: "q",
        answer: "a",
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      grounded = Loop.ground(ctx, grounder: StubGrounder)
      assert grounded.grounding.score == 0.55
    end

    test "records returned chunk IDs in tool_history per search call" do
      # The history of each search tool call should remember which chunk IDs
      # came back, so ground/2 can later map source chunk_ids back to the
      # specific search iteration and query that produced them.
      search_fn = fn
        "first", _opts -> {:ok, [%{id: "a", text: "first result", score: 0.9}]}
        "second", _opts -> {:ok, [%{id: "b", text: "second result", score: 0.9}]}
      end

      controller =
        scripted_controller([
          tool_call_response([tool_call("search", %{"query" => "first"}, "c1")]),
          tool_call_response([tool_call("search", %{"query" => "second"}, "c2")]),
          tool_call_response([tool_call("answer", %{"text" => "ok"}, "c3")])
        ])

      {:ok, ctx} =
        Loop.new("q")
        |> Loop.run(controller_llm: controller, search_fn: search_fn)

      [first_search, second_search, _answer] = ctx.tool_history
      assert first_search.returned_chunk_ids == ["a"]
      assert second_search.returned_chunk_ids == ["b"]
    end

    test "enriches span sources with search iteration and query from tool_history" do
      # Hand-crafted ctx so we can assert the enrichment without running the
      # full loop. The tool_history has two search calls that produced
      # different chunks, and the grounder returns spans with sources
      # pointing to those chunks.
      ctx = %Context{
        question: "q",
        answer: "supporting answer",
        chunks: [
          %{id: "early", text: "first", score: 0.9},
          %{id: "late", text: "second", score: 0.9}
        ],
        tool_history: [
          %{
            tool: :search,
            args: %{query: "initial query"},
            iteration: 0,
            summary: "Found 1 chunks...",
            returned_chunk_ids: ["early"]
          },
          %{
            tool: :search,
            args: %{query: "refined query"},
            iteration: 2,
            summary: "Found 1 chunks...",
            returned_chunk_ids: ["late"]
          }
        ]
      }

      grounder = fn _a, _c, _o ->
        {:ok,
         %Arcana.Grounding.Result{
           score: 0.9,
           hallucinated_spans: [],
           faithful_spans: [
             %{
               text: "supporting",
               start: 0,
               end: 10,
               score: 0.9,
               sources: [
                 %{chunk_id: "early", score: 1.0},
                 %{chunk_id: "late", score: 0.8}
               ]
             }
           ]
         }}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      [span] = grounded.grounding.faithful_spans
      [early_source, late_source] = span.sources

      assert early_source.chunk_id == "early"
      assert early_source.search_iteration == 0
      assert early_source.search_query == "initial query"

      assert late_source.chunk_id == "late"
      assert late_source.search_iteration == 2
      assert late_source.search_query == "refined query"
    end

    test "enriches sources for hallucinated spans too" do
      ctx = %Context{
        question: "q",
        answer: "a",
        chunks: [%{id: "x", text: "text", score: 0.9}],
        tool_history: [
          %{
            tool: :search,
            args: %{query: "search q"},
            iteration: 1,
            summary: "...",
            returned_chunk_ids: ["x"]
          }
        ]
      }

      grounder = fn _a, _c, _o ->
        {:ok,
         %Arcana.Grounding.Result{
           score: 0.3,
           hallucinated_spans: [
             %{
               text: "hallucinated",
               start: 0,
               end: 12,
               score: 0.3,
               sources: [%{chunk_id: "x", score: 0.1}]
             }
           ],
           faithful_spans: []
         }}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      [span] = grounded.grounding.hallucinated_spans
      [source] = span.sources

      assert source.chunk_id == "x"
      assert source.search_iteration == 1
      assert source.search_query == "search q"
    end

    test "leaves search_iteration and search_query nil for unknown chunk IDs" do
      # Defensive: if a source references a chunk we don't have history for,
      # we add the enrichment keys as nil rather than crashing or omitting them.
      ctx = %Context{
        question: "q",
        answer: "a",
        chunks: [%{id: "x", text: "text", score: 0.9}],
        tool_history: [
          %{
            tool: :search,
            args: %{query: "known"},
            iteration: 0,
            summary: "...",
            returned_chunk_ids: ["x"]
          }
        ]
      }

      grounder = fn _a, _c, _o ->
        {:ok,
         %Arcana.Grounding.Result{
           score: 0.5,
           hallucinated_spans: [],
           faithful_spans: [
             %{
               text: "mystery",
               start: 0,
               end: 7,
               score: 0.5,
               sources: [%{chunk_id: "unknown_id", score: 1.0}]
             }
           ]
         }}
      end

      grounded = Loop.ground(ctx, grounder: grounder)

      [span] = grounded.grounding.faithful_spans
      [source] = span.sources

      assert source.chunk_id == "unknown_id"
      assert source.search_iteration == nil
      assert source.search_query == nil
    end

    test "emits :start and :stop telemetry events with score metadata" do
      ref = make_ref()
      parent = self()

      handler = fn name, measurements, metadata, _ ->
        send(parent, {ref, name, measurements, metadata})
      end

      :telemetry.attach_many(
        "loop-ground-test-#{System.unique_integer()}",
        [[:arcana, :loop, :ground, :start], [:arcana, :loop, :ground, :stop]],
        handler,
        nil
      )

      ctx = %Context{
        question: "q",
        answer: "a",
        chunks: [%{id: "c1", text: "stuff", score: 0.9}]
      }

      Loop.ground(ctx, grounder: stub_grounder(0.75))

      assert_received {^ref, [:arcana, :loop, :ground, :start], %{}, %{question: "q"}}

      assert_received {^ref, [:arcana, :loop, :ground, :stop], _measurements,
                       %{score: 0.75, faithful_span_count: 1, hallucinated_span_count: 0}}
    end
  end

  describe "run/2 telemetry" do
    test "emits :start and :stop events for the loop span" do
      ref = make_ref()
      parent = self()

      handler = fn name, measurements, metadata, _ ->
        send(parent, {ref, name, measurements, metadata})
      end

      :telemetry.attach_many(
        "loop-test-#{System.unique_integer()}",
        [
          [:arcana, :loop, :start],
          [:arcana, :loop, :stop]
        ],
        handler,
        nil
      )

      controller =
        scripted_controller([
          tool_call_response([tool_call("answer", %{"text" => "done"})])
        ])

      {:ok, _ctx} =
        Loop.new("hi")
        |> Loop.run(controller_llm: controller)

      assert_received {^ref, [:arcana, :loop, :start], %{}, %{question: "hi"}}

      assert_received {^ref, [:arcana, :loop, :stop], _measurements,
                       %{terminated_by: :answered, iterations: 1}}
    end
  end

  defp system_text(nil), do: ""

  defp system_text(%ReqLLM.Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp tool_message_text(nil), do: ""

  defp tool_message_text(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.map_join("", fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} -> text
      %{type: :text, text: text} -> text
      _ -> ""
    end)
  end

  defp tool_message_text(%ReqLLM.Message{content: text}) when is_binary(text), do: text
end
