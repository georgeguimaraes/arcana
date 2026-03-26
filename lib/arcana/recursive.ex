defmodule Arcana.Recursive do
  @moduledoc """
  LLM-driven document exploration inspired by Recursive Language Models.

  Unlike the traditional RAG pipeline (`Arcana.Agent`), this module gives
  the LLM tools to navigate full document text directly. No embeddings,
  no chunking, no vector search. Documents are stored as full text and
  the LLM greps through them.

  ## Example

      # With content directly (no DB)
      {:ok, result} = Arcana.Recursive.explore(
        "What caused the revenue increase?",
        model: "anthropic:claude-sonnet-4-20250514",
        content: File.read!("report.txt")
      )

      # Multi-document
      {:ok, result} = Arcana.Recursive.explore(
        "Compare these reports",
        model: "anthropic:claude-sonnet-4-20250514",
        content: [
          %{name: "q3.txt", text: File.read!("q3.txt")},
          %{name: "q4.txt", text: File.read!("q4.txt")}
        ]
      )

      result.answer       # final answer
      result.trace        # tool call history
      result.workspace    # the workspace with documents

  ## How It Works

  1. Content loaded into workspace (from content or DB collection)
  2. System prompt built with workspace overview (document names, sizes)
  3. LLM called with tools via ReqLLM
  4. LLM calls tools (grep, read_section, sub_explore) to navigate content
  5. Tool results appended to conversation, loop continues
  6. LLM calls `answer` tool when ready → done
  7. Max steps enforced as safety limit

  ## Options

    * `:model` - LLM model string, e.g. `"anthropic:claude-sonnet-4-20250514"` (required)
    * `:content` - String or list of `%{name, text}` maps (no DB needed)
    * `:repo` - Ecto repo module (for collection-backed mode)
    * `:collection` - Collection name (default: `"default"`)
    * `:max_steps` - Maximum tool-use iterations (default: `Session.default_max_steps/0`)
    * `:max_depth` - Maximum sub_explore recursion depth (default: 3)
    * `:tools` - Additional custom `ReqLLM.Tool` structs
    * `:system_prompt` - Override the default system prompt
    * `:on_tool_call` - Callback `fn name, args, result -> :ok end`
    * `:api_key` - API key for the model provider
    * `:temperature` - LLM temperature
  """

  alias Arcana.Recursive.{Session, Workspace, Result, Tools}

  @doc """
  Stores a document for later exploration. No chunking, no embedding.

  The document is stored as full text in the existing `arcana_documents` table
  with `status: :completed` (no processing pipeline needed).

  ## Options

    * `:repo` - Ecto repo module (required)
    * `:collection` - Collection name (default: `"default"`)
    * `:name` - Document name/identifier (stored as `file_path`)
    * `:metadata` - Optional map of metadata

  ## Examples

      {:ok, doc} = Arcana.Recursive.store("The 2008 financial crisis...",
        repo: MyApp.Repo,
        collection: "research",
        name: "q3-report.pdf"
      )

  """
  @spec store(String.t(), keyword()) :: {:ok, Arcana.Document.t()} | {:error, term()}
  def store(content, opts) when is_binary(content) do
    repo = opts[:repo] || raise ArgumentError, ":repo is required"
    collection_name = Keyword.get(opts, :collection, "default")
    name = opts[:name]
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, collection} <- Arcana.Collection.get_or_create(collection_name, repo) do
      %Arcana.Document{}
      |> Arcana.Document.changeset(%{
        content: content,
        file_path: name,
        metadata: metadata,
        status: :completed,
        collection_id: collection.id
      })
      |> repo.insert()
    end
  end

  @doc """
  Explores documents to answer a question using LLM-directed tool use.

  Returns `{:ok, %Result{}}` or `{:error, reason}`.
  """
  @spec explore(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def explore(question, opts) when is_binary(question) do
    start_metadata = %{question: question, model: opts[:model], depth: opts[:depth] || 0}

    :telemetry.span([:arcana, :recursive, :explore], start_metadata, fn ->
      session = build_session(question, opts)

      :telemetry.execute([:arcana, :recursive, :session_init], %{}, %{
        question: question,
        document_count: Workspace.document_count(session.workspace),
        total_lines: Workspace.total_lines(session.workspace),
        total_bytes: Workspace.total_bytes(session.workspace),
        doc_ids: Workspace.doc_ids(session.workspace),
        depth: session.depth
      })

      case run_loop(session) do
        %Session{error: nil, answer: answer} = final ->
          result = build_result(final)

          {{:ok, result},
           %{
             step_count: final.step_count,
             answer_length: String.length(answer),
             input_tokens: final.usage.input_tokens,
             output_tokens: final.usage.output_tokens
           }}

        %Session{error: reason} = final ->
          {{:error, reason}, %{step_count: final.step_count, error: reason}}
      end
    end)
  end

  @doc "Same as `explore/2` but raises on error."
  @spec explore!(String.t(), keyword()) :: Result.t()
  def explore!(question, opts) do
    case explore(question, opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "Arcana.Recursive exploration failed: #{inspect(reason)}"
    end
  end

  # --- Session Setup ---

  defp build_session(question, opts) do
    collections = build_collections(opts)
    workspace = build_workspace(opts, collections)

    llm_opts =
      opts
      |> Keyword.take([:api_key, :temperature, :max_tokens, :provider_options])
      |> Keyword.reject(fn {_k, v} -> is_nil(v) end)

    session_opts = [
      depth: Keyword.get(opts, :depth, 0),
      max_depth: Keyword.get(opts, :max_depth, 3)
    ]

    tools = Tools.build(session_opts, Keyword.get(opts, :tools, []))

    %Session{
      question: question,
      model: opts[:model],
      repo: opts[:repo],
      max_steps: Keyword.get(opts, :max_steps, Session.default_max_steps()),
      max_depth: Keyword.get(opts, :max_depth, 3),
      depth: Keyword.get(opts, :depth, 0),
      collections: collections,
      llm_opts: llm_opts,
      tools: tools,
      workspace: workspace,
      on_tool_call: opts[:on_tool_call],
      on_trace_entry: opts[:on_trace_entry],
      session_id: Keyword.get(opts, :session_id, "root")
    }
  end

  defp build_workspace(opts, collections) do
    cond do
      opts[:workspace] ->
        opts[:workspace]

      opts[:content] ->
        Workspace.from_content(opts[:content])

      opts[:repo] ->
        load_collection(opts[:repo], collections)

      true ->
        Workspace.new()
    end
  end

  defp load_collection(repo, collection_names) do
    import Ecto.Query

    documents =
      from(d in Arcana.Document,
        join: c in Arcana.Collection,
        on: d.collection_id == c.id,
        where: c.name in ^collection_names and d.status == :completed,
        select: %{name: d.file_path, text: d.content, id: d.id, metadata: d.metadata}
      )
      |> repo.all()
      |> Enum.map(fn doc ->
        title = get_in(doc.metadata || %{}, ["title"])
        name = doc.name || title || doc.id
        %{name: name, text: doc.text, id: doc.id}
      end)

    Workspace.from_content(documents)
  end

  defp build_collections(opts) do
    cond do
      opts[:collections] -> opts[:collections]
      opts[:collection] -> [opts[:collection]]
      true -> ["default"]
    end
  end

  # --- Tool-Use Loop ---

  defp run_loop(%Session{step_count: step, max_steps: max} = session) when step >= max do
    :telemetry.execute([:arcana, :recursive, :max_steps_reached], %{}, %{
      step_count: step,
      max_steps: max,
      question: session.question,
      depth: session.depth
    })

    force_answer(session)
  end

  defp run_loop(%Session{answer: answer} = session) when not is_nil(answer) do
    session
  end

  defp run_loop(%Session{} = session) do
    context = build_context(session)

    case call_llm(session, context) do
      {:ok, response, updated_session} ->
        tool_calls =
          response
          |> ReqLLM.Response.tool_calls()
          |> Enum.map(&normalize_tool_call/1)

        if tool_calls != [] do
          updated_session
          |> process_tool_calls(tool_calls, response)
          |> run_loop()
        else
          text = ReqLLM.Response.text(response) || ""

          if text != "" do
            %{updated_session | answer: text}
          else
            force_answer(updated_session)
          end
        end

      {:error, reason} ->
        %{session | error: reason}
    end
  end

  defp call_llm(%Session{} = session, context) do
    opts = Keyword.merge(session.llm_opts, tools: session.tools)

    case Arcana.LLM.Helpers.chat(session.model, context, opts) do
      {:ok, %ReqLLM.Response{} = response} ->
        updated = Session.accumulate_usage(session, response.usage)
        merged_context = ReqLLM.Context.merge_response(context, response, tools: session.tools)
        {:ok, response, %{updated | context: merged_context.context}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Context Building ---

  defp build_context(%Session{context: nil} = session) do
    system_prompt = build_system_prompt(session)

    ReqLLM.Context.new([
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(session.question)
    ])
  end

  defp build_context(%Session{context: %ReqLLM.Context{} = context} = session) do
    system_prompt = build_system_prompt(session)
    system_msg = ReqLLM.Context.system(system_prompt)

    updated_messages =
      case context.messages do
        [%{role: :system} | rest] -> [system_msg | rest]
        messages -> [system_msg | messages]
      end

    %{context | messages: updated_messages}
  end

  defp build_system_prompt(%Session{} = session) do
    workspace_overview = Workspace.overview(session.workspace)
    has_sub_explore = Enum.any?(session.tools, &(&1.name == "sub_explore"))

    """
    You are a research agent exploring documents to answer a question.

    ## Your Tools
    - grep(pattern): Search all documents for lines matching a regex pattern. Returns matching lines with document name and line number.
    - read_section(document, start_line, end_line): Read a range of lines from a specific document. Use grep results to find interesting areas, then read_section for full context.#{if has_sub_explore, do: "\n- sub_explore(task, documents): Delegate a focused subtask to a sub-agent with a subset of documents.", else: ""}

    ## Strategy
    1. Start with grep to find relevant sections across all documents
    2. Use read_section to examine promising areas in full context
    3. Grep with different patterns to explore different aspects#{if has_sub_explore, do: "\n    4. When analyzing multiple documents, prefer sub_explore to delegate focused analysis of each document to a sub-agent. This is faster and more thorough than reading everything yourself.\n    5. Use sub_explore liberally: one sub-agent per document or per subtopic. You can dispatch multiple sub_explores in a single response and they will run in parallel.", else: ""}
    #{if has_sub_explore, do: "6", else: "4"}. When you have enough evidence, respond with your answer directly (no tool call needed)

    ## Important
    - Documents are NOT in your context window. You must use grep and read_section to access their content.
    - grep is case insensitive and supports regex.
    - Be specific with read_section ranges to avoid reading entire documents unnecessarily.#{if has_sub_explore, do: "\n    - Prefer sub_explore over manual grep+read_section when you need to analyze a document in depth.", else: ""}
    - When ready, just respond with your answer as plain text. Don't over-search.

    ## Current Workspace
    #{workspace_overview}
    """
  end

  # --- Tool Execution ---

  defp process_tool_calls(session, tool_calls, response) do
    context =
      if session.context do
        session.context
      else
        ctx = build_context(session)
        merged = ReqLLM.Context.merge_response(ctx, response, tools: session.tools)
        merged.context
      end

    session = %{session | context: context}

    {sub_explores, others} =
      Enum.split_with(tool_calls, &(&1.name == "sub_explore"))

    # Execute non-sub_explore tools sequentially (they mutate session state)
    session = Enum.reduce(others, session, &execute_tool(&2, &1))

    case sub_explores do
      [] -> session
      [single] -> execute_tool(session, single)
      multiple -> execute_sub_explores(session, multiple)
    end
  end

  defp execute_sub_explores(session, sub_explore_calls) do
    case Process.whereis(Arcana.TaskSupervisor) do
      nil -> execute_sub_explores_sequential(session, sub_explore_calls)
      _pid -> execute_sub_explores_parallel(session, sub_explore_calls)
    end
  end

  defp execute_sub_explores_sequential(session, sub_explore_calls) do
    Enum.reduce(sub_explore_calls, session, &execute_tool(&2, &1))
  end

  defp execute_sub_explores_parallel(session, sub_explore_calls) do
    start_time = System.monotonic_time(:millisecond)

    # Pre-generate child session IDs so parent trace entries can reference them
    calls_with_ids =
      Enum.map(sub_explore_calls, fn call ->
        {call, generate_session_id()}
      end)

    # Run each sub_explore in a supervised task. We only need the pure
    # result (answer text + usage) since sub_explores don't mutate the
    # parent workspace. Session state (trace, context) is merged back
    # sequentially after all tasks complete.
    results =
      Arcana.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        calls_with_ids,
        fn {%{arguments: args}, child_session_id} ->
          task_start = System.monotonic_time(:millisecond)
          result = run_sub_explore_task(session, args, child_session_id)
          task_duration = System.monotonic_time(:millisecond) - task_start
          {result, task_duration}
        end,
        max_concurrency: length(sub_explore_calls),
        timeout: :timer.minutes(5),
        ordered: true
      )
      |> Enum.zip(calls_with_ids)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    :telemetry.execute([:arcana, :recursive, :parallel_sub_explore], %{}, %{
      count: length(sub_explore_calls),
      duration_ms: duration_ms,
      depth: session.depth
    })

    # Merge results back into session sequentially
    Enum.reduce(results, session, fn {task_result, {tool_call, child_session_id}}, acc ->
      %{id: call_id, name: name, arguments: args} = tool_call

      {result_text, sub_usage, task_duration_ms} =
        case task_result do
          {:ok, {{:ok, answer, usage}, task_ms}} ->
            {answer, usage, task_ms}

          {:ok, {{:error, reason}, task_ms}} ->
            {"Sub-exploration failed: #{inspect(reason)}", %{input_tokens: 0, output_tokens: 0},
             task_ms}

          {:exit, reason} ->
            {"Sub-exploration crashed: #{inspect(reason)}", %{input_tokens: 0, output_tokens: 0},
             duration_ms}
        end

      updated_usage = %{
        input_tokens: acc.usage.input_tokens + sub_usage.input_tokens,
        output_tokens: acc.usage.output_tokens + sub_usage.output_tokens
      }

      acc = %{acc | usage: updated_usage}

      # Include child_session_id in args so the trace entry links parent → child
      args_with_child = Map.put(args, "child_session_id", child_session_id)

      acc =
        acc
        |> Session.record_tool_call(
          name,
          args_with_child,
          truncate(result_text, 200),
          task_duration_ms
        )
        |> Session.increment_step()

      if acc.on_tool_call do
        acc.on_tool_call.(name, args_with_child, truncate(result_text, 200))
      end

      tool_result_msg = ReqLLM.Context.tool_result(call_id, name, result_text)
      updated_context = ReqLLM.Context.append(acc.context, tool_result_msg)
      %{acc | context: updated_context}
    end)
  end

  # Pure function that runs a sub_explore and returns the result without
  # mutating any session state. Safe to call from a Task.
  defp run_sub_explore_task(session, args, child_session_id) do
    task = Map.get(args, "task", "")
    documents = Map.get(args, "documents", [])

    if session.depth >= session.max_depth do
      {:error, "maximum recursion depth (#{session.max_depth}) reached"}
    else
      sub_workspace = Workspace.subset(session.workspace, documents)
      sid = child_session_id || generate_session_id()

      sub_opts =
        [
          model: session.model,
          repo: session.repo,
          collections: session.collections,
          max_steps: div(session.max_steps, 2),
          max_depth: session.max_depth,
          depth: session.depth + 1,
          workspace: sub_workspace,
          on_tool_call: session.on_tool_call,
          on_trace_entry: session.on_trace_entry,
          session_id: sid
        ] ++ session.llm_opts

      case explore(task, sub_opts) do
        {:ok, sub_result} -> {:ok, sub_result.answer, sub_result.usage}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp generate_session_id do
    Uniq.UUID.uuid7() |> String.slice(0, 8)
  end

  defp execute_tool(session, %{name: name, arguments: args, id: call_id}) do
    start_time = System.monotonic_time(:millisecond)

    :telemetry.span(
      [:arcana, :recursive, :tool_call],
      %{tool: name, step: session.step_count, depth: session.depth},
      fn ->
        {result_text, updated_session, trace_args} = do_execute_tool(session, name, args)

        duration_ms = System.monotonic_time(:millisecond) - start_time

        updated_session =
          updated_session
          |> Session.record_tool_call(name, trace_args, truncate(result_text, 200), duration_ms)
          |> Session.increment_step()

        if updated_session.on_tool_call do
          updated_session.on_tool_call.(name, trace_args, truncate(result_text, 200))
        end

        tool_result_msg = ReqLLM.Context.tool_result(call_id, name, result_text)
        updated_context = ReqLLM.Context.append(updated_session.context, tool_result_msg)
        final_session = %{updated_session | context: updated_context}

        {final_session,
         %{
           tool: name,
           args: trace_args,
           result_preview: truncate(result_text, 200),
           duration_ms: duration_ms,
           step: session.step_count
         }}
      end
    )
  end

  defp do_execute_tool(session, "grep", args) do
    pattern = Map.get(args, "pattern", "")

    case Workspace.grep(session.workspace, pattern) do
      {:ok, []} ->
        {"No matches found for pattern: #{pattern}", session, args}

      {:ok, matches} ->
        result_text =
          Enum.map_join(matches, "\n", fn m ->
            "  #{m.document}:#{m.line_number}  #{m.line}"
          end)

        {"Found #{length(matches)} matches:\n#{result_text}", session, args}

      {:error, reason} ->
        {"Error: invalid regex pattern '#{pattern}': #{inspect(reason)}", session, args}
    end
  end

  defp do_execute_tool(session, "read_section", args) do
    doc_name = Map.get(args, "document", "")
    start_line = Map.get(args, "start_line")
    end_line = Map.get(args, "end_line")

    range =
      case {start_line, end_line} do
        {nil, nil} -> :all
        {s, nil} -> {s, 999_999}
        {nil, e} -> {1, e}
        {s, e} -> {s, e}
      end

    case Workspace.read_section(session.workspace, doc_name, range) do
      {:ok, text} ->
        {text, session, args}

      {:error, :not_found} ->
        doc_names = session.workspace.documents |> Map.keys() |> Enum.join(", ")
        {"Error: document '#{doc_name}' not found. Available: #{doc_names}", session, args}
    end
  end

  defp do_execute_tool(session, "sub_explore", args) do
    child_session_id = generate_session_id()
    args_with_child = Map.put(args, "child_session_id", child_session_id)

    case run_sub_explore_task(session, args, child_session_id) do
      {:ok, answer, sub_usage} ->
        updated_usage = %{
          input_tokens: session.usage.input_tokens + sub_usage.input_tokens,
          output_tokens: session.usage.output_tokens + sub_usage.output_tokens
        }

        {answer, %{session | usage: updated_usage}, args_with_child}

      {:error, reason} ->
        {"Sub-exploration failed: #{inspect(reason)}", session, args_with_child}
    end
  end

  defp do_execute_tool(session, unknown_tool, args) do
    case Enum.find(session.tools, &(&1.name == unknown_tool)) do
      nil ->
        {"Error: unknown tool '#{unknown_tool}'", session, args}

      tool ->
        case ReqLLM.Tool.execute(tool, args) do
          {:ok, result} ->
            result_text = if is_binary(result), do: result, else: JSON.encode!(result)
            {result_text, session, args}

          {:error, reason} ->
            {"Error executing #{unknown_tool}: #{inspect(reason)}", session, args}
        end
    end
  end

  # --- Helpers ---

  defp force_answer(%Session{} = session) do
    workspace_overview = Workspace.overview(session.workspace)

    prompt =
      "Based on the information gathered, provide your best answer to: #{session.question}\n\nWorkspace:\n#{workspace_overview}"

    case call_force_answer_llm(session, prompt) do
      {:ok, text, usage} -> %{session | answer: text} |> Session.accumulate_usage(usage)
      {:error, reason} -> %{session | error: reason}
    end
  end

  defp call_force_answer_llm(%Session{} = session, prompt) do
    context = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

    case Arcana.LLM.Helpers.chat(session.model, context, session.llm_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.text(response) || "", response.usage}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_result(%Session{} = session) do
    %Result{
      answer: session.answer,
      workspace: session.workspace,
      trace: session.trace,
      usage: session.usage,
      depth: session.depth,
      step_count: session.step_count
    }
  end

  defp normalize_tool_call(%ReqLLM.ToolCall{} = tc) do
    %{name: ReqLLM.ToolCall.name(tc), arguments: ReqLLM.ToolCall.args_map(tc), id: tc.id}
  end

  defp normalize_tool_call(%{name: _, arguments: _, id: _} = tc), do: tc

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defp truncate(other, _max_length), do: inspect(other)
end
