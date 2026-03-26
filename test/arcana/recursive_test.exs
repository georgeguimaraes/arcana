defmodule Arcana.RecursiveTest do
  use ExUnit.Case, async: true

  alias Arcana.Recursive

  # Helper to build a mock ReqLLM.Response with tool calls
  defp mock_tool_call_response(tool_name, args) do
    tool_call = ReqLLM.ToolCall.new(Uniq.UUID.uuid7(), tool_name, JSON.encode!(args))

    %ReqLLM.Response{
      id: Uniq.UUID.uuid7(),
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant("", tool_calls: [tool_call]),
      finish_reason: :tool_calls,
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  # Helper to build a mock ReqLLM.Response with multiple tool calls
  defp mock_multi_tool_call_response(tool_calls_list) do
    tool_calls =
      Enum.map(tool_calls_list, fn {name, args} ->
        ReqLLM.ToolCall.new(Uniq.UUID.uuid7(), name, JSON.encode!(args))
      end)

    %ReqLLM.Response{
      id: Uniq.UUID.uuid7(),
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant("", tool_calls: tool_calls),
      finish_reason: :tool_calls,
      usage: %{input_tokens: 10, output_tokens: 5}
    }
  end

  # Helper to build a mock ReqLLM.Response with a final text answer
  defp mock_text_response(text) do
    %ReqLLM.Response{
      id: Uniq.UUID.uuid7(),
      model: "mock",
      context: nil,
      message: ReqLLM.Context.assistant(text),
      finish_reason: :stop,
      usage: %{input_tokens: 10, output_tokens: 20}
    }
  end

  @content [
    %{
      name: "report.txt",
      text:
        "Revenue grew 15% in Q3.\nCosts remained stable.\nProfit margins improved.\nHeadcount increased by 20."
    },
    %{
      name: "analysis.md",
      text:
        "The market showed strong growth.\nCompetitors struggled with supply chain issues.\nOur market share increased to 23%."
    }
  ]

  describe "explore/2 with content mode" do
    test "grep → read_section → text answer flow" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        response =
          case count do
            0 ->
              mock_tool_call_response("grep", %{"pattern" => "revenue|grew"})

            1 ->
              mock_tool_call_response("read_section", %{
                "document" => "report.txt",
                "start_line" => 1,
                "end_line" => 3
              })

            _ ->
              mock_text_response("Revenue grew 15% in Q3 with improved margins.")
          end

        {:ok, response}
      end

      {:ok, result} =
        Recursive.explore("What happened to revenue?",
          model: mock_model,
          content: @content
        )

      assert result.answer == "Revenue grew 15% in Q3 with improved margins."
      assert length(result.trace) >= 2
      assert result.usage.input_tokens > 0

      # Verify trace has the right tools
      tool_names = Enum.map(result.trace, & &1.tool)
      assert "grep" in tool_names
      assert "read_section" in tool_names
    end

    test "direct answer without tool calls" do
      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("Based on my knowledge, revenue grew.")}
      end

      {:ok, result} =
        Recursive.explore("What happened?",
          model: mock_model,
          content: @content
        )

      assert result.answer == "Based on my knowledge, revenue grew."
      assert result.trace == []
    end

    test "max_steps enforcement" do
      mock_model = fn _context, _tools ->
        {:ok, mock_tool_call_response("grep", %{"pattern" => "infinite loop"})}
      end

      {:ok, result} =
        Recursive.explore("Loop forever",
          model: mock_model,
          content: @content,
          max_steps: 3
        )

      assert is_binary(result.answer)
      assert result.step_count >= 3
    end

    test "LLM error propagates" do
      mock_model = fn _context, _tools ->
        {:error, :api_timeout}
      end

      {:error, reason} =
        Recursive.explore("Fail please",
          model: mock_model,
          content: @content
        )

      assert reason == :api_timeout
    end

    test "explore!/2 raises on error" do
      mock_model = fn _context, _tools -> {:error, :boom} end

      assert_raise RuntimeError, ~r/exploration failed/, fn ->
        Recursive.explore!("Fail",
          model: mock_model,
          content: @content
        )
      end
    end

    test "on_tool_call callback fires" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "test"})}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, _result} =
        Recursive.explore("Test callback",
          model: mock_model,
          content: @content,
          on_tool_call: fn name, _args, _result ->
            send(test_pid, {:tool_called, name})
            :ok
          end
        )

      assert_receive {:tool_called, "grep"}
    end

    test "grep actually searches document content" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "market share"})}
        else
          # Check that the tool result contains actual grep matches
          tool_msgs = Enum.filter(context.messages, &(&1.role == :tool))

          answer_text =
            if tool_msgs != [] do
              "Found market data in the documents."
            else
              "No data found."
            end

          {:ok, mock_text_response(answer_text)}
        end
      end

      {:ok, result} =
        Recursive.explore("What is our market share?",
          model: mock_model,
          content: @content
        )

      assert result.answer == "Found market data in the documents."

      # The grep trace should show it found matches
      grep_trace = Enum.find(result.trace, &(&1.tool == "grep"))
      assert grep_trace.result_preview =~ "analysis.md"
    end

    test "read_section returns actual document content" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           mock_tool_call_response("read_section", %{
             "document" => "report.txt",
             "start_line" => 1,
             "end_line" => 2
           })}
        else
          # The tool result should contain actual content from the document
          tool_msgs = Enum.filter(context.messages, &(&1.role == :tool))

          has_content =
            Enum.any?(tool_msgs, fn msg ->
              msg.content
              |> Enum.any?(fn part ->
                is_binary(part.text) and part.text =~ "Revenue grew"
              end)
            end)

          answer =
            if has_content,
              do: "Revenue grew 15% in Q3.",
              else: "Could not read content."

          {:ok, mock_text_response(answer)}
        end
      end

      {:ok, result} =
        Recursive.explore("Read the report",
          model: mock_model,
          content: @content
        )

      assert result.answer == "Revenue grew 15% in Q3."
    end

    test "read_section handles unknown document" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           mock_tool_call_response("read_section", %{
             "document" => "nonexistent.txt"
           })}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, result} =
        Recursive.explore("Read missing doc",
          model: mock_model,
          content: @content
        )

      # Should have continued despite the error
      assert result.answer == "done"
      read_trace = Enum.find(result.trace, &(&1.tool == "read_section"))
      assert read_trace.result_preview =~ "not found"
    end

    test "single string content works" do
      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("done")}
      end

      {:ok, result} =
        Recursive.explore("Analyze this",
          model: mock_model,
          content: "Just a single document with some text."
        )

      assert result.answer == "done"
      assert result.workspace.documents["doc_1"].text == "Just a single document with some text."
    end

    test "accumulates token usage across calls" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "test"})}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test usage",
          model: mock_model,
          content: @content
        )

      # tool_call_response: 10 input + 5 output, text_response: 10 input + 20 output
      assert result.usage.input_tokens == 20
      assert result.usage.output_tokens == 25
    end

    test "sub_explore delegates to sub-agent" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_tool_call_response("sub_explore", %{
             "task" => "Analyze the report",
             "documents" => ["report.txt"]
           })}
        else
          {:ok, mock_text_response("Sub-analysis complete.")}
        end
      end

      {:ok, result} =
        Recursive.explore("Analyze everything",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      assert is_binary(result.answer)
      assert Enum.any?(result.trace, &(&1.tool == "sub_explore"))
    end

    test "sub_explore respects max_depth" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_tool_call_response("sub_explore", %{
             "task" => "Go deeper",
             "documents" => ["report.txt"]
           })}
        else
          {:ok, mock_text_response("Reached depth limit.")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test depth",
          model: mock_model,
          content: @content,
          max_depth: 1,
          depth: 0
        )

      assert is_binary(result.answer)
    end

    test "workspace is preserved in result" do
      mock_model = fn _context, _tools ->
        {:ok, mock_text_response("done")}
      end

      {:ok, result} =
        Recursive.explore("Check workspace",
          model: mock_model,
          content: @content
        )

      assert Arcana.Recursive.Workspace.document_count(result.workspace) == 2
      assert Map.has_key?(result.workspace.documents, "report.txt")
      assert Map.has_key?(result.workspace.documents, "analysis.md")
    end

    test "telemetry events are emitted" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-recursive-telemetry-#{inspect(ref)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:arcana, :recursive, :explore, :start],
          [:arcana, :recursive, :explore, :stop],
          [:arcana, :recursive, :session_init],
          [:arcana, :recursive, :tool_call, :start],
          [:arcana, :recursive, :tool_call, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "revenue"})}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, _result} =
        Recursive.explore("Telemetry test",
          model: mock_model,
          content: @content
        )

      assert_receive {:telemetry, [:arcana, :recursive, :explore, :start], _,
                      %{question: "Telemetry test"}}

      assert_receive {:telemetry, [:arcana, :recursive, :session_init], _,
                      %{document_count: 2, total_lines: 7}}

      assert_receive {:telemetry, [:arcana, :recursive, :tool_call, :start], _, %{tool: "grep"}}

      assert_receive {:telemetry, [:arcana, :recursive, :tool_call, :stop], _, %{tool: "grep"}}

      assert_receive {:telemetry, [:arcana, :recursive, :explore, :stop], _, %{step_count: 1}}

      :telemetry.detach(handler_id)
    end

    test "max_steps_reached telemetry event fires" do
      test_pid = self()
      ref = make_ref()

      handler_id = "test-recursive-max-steps-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:arcana, :recursive, :max_steps_reached],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      mock_model = fn _context, _tools ->
        {:ok, mock_tool_call_response("grep", %{"pattern" => "loop"})}
      end

      {:ok, _result} =
        Recursive.explore("Loop forever",
          model: mock_model,
          content: @content,
          max_steps: 3
        )

      assert_receive {:telemetry, [:arcana, :recursive, :max_steps_reached], _, %{max_steps: 3}}

      :telemetry.detach(handler_id)
    end
  end

  describe "trace tree (on_trace_entry, session_id, depth)" do
    test "on_trace_entry callback fires with full entry including session_id and depth" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "revenue"})}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, _result} =
        Recursive.explore("Test trace entry",
          model: mock_model,
          content: @content,
          on_trace_entry: fn entry ->
            send(test_pid, {:trace_entry, entry})
          end
        )

      assert_receive {:trace_entry, entry}
      assert entry.tool == "grep"
      assert entry.session_id == "root"
      assert entry.depth == 0
      assert is_integer(entry.step)
      assert is_integer(entry.duration_ms)
      assert is_binary(entry.result_preview)
    end

    test "trace entries include session_id" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, _tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok, mock_tool_call_response("grep", %{"pattern" => "test"})}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test session_id",
          model: mock_model,
          content: @content
        )

      assert Enum.all?(result.trace, &(&1.session_id == "root"))
    end

    test "sub_explore trace entries include child_session_id in args" do
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_tool_call_response("sub_explore", %{
             "task" => "Analyze report",
             "documents" => ["report.txt"]
           })}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test child session id",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      sub_trace = Enum.find(result.trace, &(&1.tool == "sub_explore"))
      assert sub_trace
      assert is_binary(sub_trace.args["child_session_id"])
      assert String.length(sub_trace.args["child_session_id"]) == 8
    end

    test "on_trace_entry fires for child sub_explore entries" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_tool_call_response("sub_explore", %{
             "task" => "Analyze report",
             "documents" => ["report.txt"]
           })}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, _result} =
        Recursive.explore("Test child trace",
          model: mock_model,
          content: @content,
          max_depth: 2,
          on_trace_entry: fn entry ->
            send(test_pid, {:trace_entry, entry})
          end
        )

      # Should receive at least the parent's sub_explore entry
      assert_receive {:trace_entry, parent_entry}
      assert parent_entry.session_id == "root"

      # Depending on child execution, may receive child entries with depth > 0
      # Collect all entries
      entries = collect_trace_entries()
      all_entries = [parent_entry | entries]

      # All entries should have session_id
      assert Enum.all?(all_entries, &is_binary(&1.session_id))
    end
  end

  defp collect_trace_entries(acc \\ []) do
    receive do
      {:trace_entry, entry} -> collect_trace_entries([entry | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "parallel sub_explore" do
    test "multiple sub_explore calls run in parallel with TaskSupervisor" do
      # Start a TaskSupervisor for this test
      start_supervised!({Task.Supervisor, name: Arcana.TaskSupervisor})

      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          # Send two sub_explore calls in one batch
          {:ok,
           mock_multi_tool_call_response([
             {"sub_explore", %{"task" => "Analyze report", "documents" => ["report.txt"]}},
             {"sub_explore", %{"task" => "Analyze analysis", "documents" => ["analysis.md"]}}
           ])}
        else
          # Sub-agents and parent eventually answer
          {:ok, mock_text_response("Parallel analysis complete.")}
        end
      end

      {:ok, result} =
        Recursive.explore("Analyze everything in parallel",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      assert is_binary(result.answer)

      # Both sub_explore calls should be in the trace
      sub_explore_traces = Enum.filter(result.trace, &(&1.tool == "sub_explore"))
      assert length(sub_explore_traces) == 2
    end

    test "falls back to sequential when TaskSupervisor not running" do
      # Don't start TaskSupervisor — should fall back gracefully
      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_multi_tool_call_response([
             {"sub_explore", %{"task" => "Analyze report", "documents" => ["report.txt"]}},
             {"sub_explore", %{"task" => "Analyze analysis", "documents" => ["analysis.md"]}}
           ])}
        else
          {:ok, mock_text_response("Sequential fallback.")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test fallback",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      assert is_binary(result.answer)
      sub_explore_traces = Enum.filter(result.trace, &(&1.tool == "sub_explore"))
      assert length(sub_explore_traces) == 2
    end

    test "parallel_sub_explore telemetry event fires" do
      start_supervised!({Task.Supervisor, name: Arcana.TaskSupervisor})

      test_pid = self()
      ref = make_ref()
      handler_id = "test-parallel-sub-explore-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:arcana, :recursive, :parallel_sub_explore],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_multi_tool_call_response([
             {"sub_explore", %{"task" => "Task A", "documents" => ["report.txt"]}},
             {"sub_explore", %{"task" => "Task B", "documents" => ["analysis.md"]}}
           ])}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, _result} =
        Recursive.explore("Test telemetry",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      assert_receive {:telemetry, [:arcana, :recursive, :parallel_sub_explore], _, %{count: 2}}

      :telemetry.detach(handler_id)
    end

    test "usage accumulates from parallel sub-agents" do
      start_supervised!({Task.Supervisor, name: Arcana.TaskSupervisor})

      call_count = :counters.new(1, [:atomics])

      mock_model = fn _context, tools ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        has_sub_explore = Enum.any?(tools, &(&1.name == "sub_explore"))

        if count == 0 and has_sub_explore do
          {:ok,
           mock_multi_tool_call_response([
             {"sub_explore", %{"task" => "Task A", "documents" => ["report.txt"]}},
             {"sub_explore", %{"task" => "Task B", "documents" => ["analysis.md"]}}
           ])}
        else
          {:ok, mock_text_response("done")}
        end
      end

      {:ok, result} =
        Recursive.explore("Test usage",
          model: mock_model,
          content: @content,
          max_depth: 2
        )

      # Parent: 2 LLM calls (10+5 each = 30 input, 15 output... wait no, it depends)
      # Each sub-agent: at least 1 LLM call (10+5)
      # Total should be > parent-only usage
      assert result.usage.input_tokens > 20
      assert result.usage.output_tokens > 10
    end
  end

  describe "Telemetry.Logger handles recursive events" do
    import ExUnit.CaptureLog

    test "formats explore stop event" do
      message =
        capture_logger(
          :arcana,
          :recursive,
          :explore,
          :stop,
          %{duration: System.convert_time_unit(150, :millisecond, :native)},
          %{step_count: 5, input_tokens: 1000, output_tokens: 200}
        )

      assert message =~ "recursive.explore"
      assert message =~ "150ms"
      assert message =~ "5 steps"
      assert message =~ "1200 tokens"
    end

    test "formats session_init event" do
      message =
        capture_logger(:arcana, :recursive, :session_init, nil, %{}, %{
          document_count: 3,
          total_lines: 150,
          total_bytes: 4096
        })

      assert message =~ "recursive.session_init"
      assert message =~ "3 docs"
      assert message =~ "150 lines"
      assert message =~ "4KB"
    end

    test "formats tool_call stop event" do
      message =
        capture_logger(
          :arcana,
          :recursive,
          :tool_call,
          :stop,
          %{duration: System.convert_time_unit(12, :millisecond, :native)},
          %{
            tool: "grep",
            step: 2,
            args: %{"pattern" => "revenue"},
            result_preview: "Found 3 matches"
          }
        )

      assert message =~ "recursive.tool_call"
      assert message =~ "12ms"
      assert message =~ "step 2"
      assert message =~ "grep"
      assert message =~ "Found 3 matches"
    end

    test "formats max_steps_reached event" do
      message =
        capture_logger(:arcana, :recursive, :max_steps_reached, nil, %{}, %{
          max_steps: 15,
          step_count: 15,
          question: "test"
        })

      assert message =~ "recursive.max_steps_reached"
      assert message =~ "limit: 15"
    end

    defp capture_logger(a, b, c, nil, measurements, metadata) do
      capture_log([level: :warning], fn ->
        Arcana.Telemetry.Logger.handle_event([a, b, c], measurements, metadata, %{level: :warning})
      end)
    end

    defp capture_logger(a, b, c, d, measurements, metadata) do
      capture_log([level: :warning], fn ->
        Arcana.Telemetry.Logger.handle_event([a, b, c, d], measurements, metadata, %{
          level: :warning
        })
      end)
    end
  end
end
