defmodule Arcana.Loop do
  @moduledoc """
  Agentic RAG via an LLM-driven tool loop.

  Where `Arcana.Pipeline` composes RAG steps that you decide ahead of time,
  `Arcana.Loop` lets the LLM decide what to do each turn. The controller
  picks tools (`search`, `answer`, `give_up`) until it has enough context
  to answer the question or hits a safety limit.

  This is the "Agentic RAG" pattern from Singh et al.'s 2025 survey: an LLM
  driven loop with tool use, as opposed to the static "Modular RAG" pipeline
  in `Arcana.Pipeline`. Both patterns are useful and they coexist.

  ## Quick start

      {:ok, ctx} =
        Arcana.Loop.new("Find episodes where a Time Lord betrayed the Doctor",
          repo: MyApp.Repo,
          collection: "doctor-who"
        )
        |> Arcana.Loop.run(controller_llm: "openai:gpt-4o-mini")

      ctx.answer
      ctx.tool_history
      ctx.terminated_by

  ## Two models

  You can configure separate models for the loop controller and the final
  answer. When `:answer_llm` is omitted the controller is used for both.

  ## Termination

  The loop terminates on any of:

    1. The controller calls the `answer` tool. `terminated_by: :answered`.
    2. The controller calls the `give_up` tool. `terminated_by: :gave_up`.
    3. `max_iterations` is reached. `terminated_by: :max_iterations`.
    4. The controller LLM returns an error. `terminated_by: :error`.
    5. The controller returns a final answer with no tool calls.
       `terminated_by: :answered`.

  ## Configuration

  Set defaults via app config. Per-call options override these.

      config :arcana, loop: [
        max_iterations: 10,
        controller_llm: "openai:gpt-4o-mini",
        chunk_cap: 30
      ]

  ## Telemetry

  Each phase emits events under `[:arcana, :loop, :*]`.

  ## References

  - [Agentic RAG Survey (Singh et al., 2025)](https://arxiv.org/abs/2501.09136)
  - [Anthropic: Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
  - [OpenAI: GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)
  """

  alias Arcana.Loop.{Context, SystemPrompt, Tools}
  alias ReqLLM.Message.ContentPart

  @doc """
  Builds a new `Arcana.Loop.Context` for `run/2`.

  ## Options

    * `:repo` - Ecto repo for retrieval tools. Falls back to `:repo` global config.
    * `:collection` - Single collection name (becomes `[collection]`).
    * `:collections` - List of collection names. Takes precedence over `:collection`.
  """
  @spec new(String.t(), keyword()) :: Context.t()
  def new(question, opts \\ []) when is_binary(question) do
    repo = Arcana.Config.get(opts, :repo)

    collections =
      case Keyword.fetch(opts, :collections) do
        {:ok, list} ->
          list

        :error ->
          case Keyword.fetch(opts, :collection) do
            {:ok, name} -> [name]
            :error -> [nil]
          end
      end

    %Context{
      question: question,
      repo: repo,
      collections: collections
    }
  end

  @doc """
  Runs the agent loop until it terminates.

  Returns `{:ok, ctx}` with the final loop context. The context's
  `:terminated_by`, `:answer`, `:tool_history`, and `:chunks` fields tell
  you what happened.

  ## Options

    * `:tools` - List of `ReqLLM.Tool` structs. Defaults to `Tools.default/0`.
    * `:max_iterations` - Hard cap on controller turns. Default 10.
    * `:controller_llm` - Model spec for the loop controller. Required.
      Either a `ReqLLM` model string or a function
      `fn messages, tools, opts -> {:ok, classified} | {:error, reason} end`.
    * `:answer_llm` - Optional model spec for the **answerer**, separate
      from the controller. When set, the loop's controller picks tools as
      usual, but the user-facing answer text is produced by the answer_llm
      via a separate tool-less LLM call. Use this for the
      "cheap controller / strong answerer" pattern: a small fast model
      drives the loop, a stronger model writes the final answer. Triggers
      on the `answer` tool path (rewrites the controller's draft) and on
      the `max_iterations` synthesis fallback (used as the default
      synthesizer). Does **not** rewrite `give_up` (which would just dress
      up failure in nicer prose). When unset, the controller's text is
      used as `ctx.answer` directly.
    * `:system_prompt` - Override the default system prompt. Either a
      string or a function `fn opts -> string end`.
    * `:chunk_cap` - Maximum chunks accumulated across iterations. Default 30.
    * `:search_fn` - Override `Arcana.search/2` for the built-in `search` tool.
      Used in tests; receives `(query, search_opts)`.
    * `:search_opts` - Extra options forwarded to the `search` tool's call into
      `Arcana.search/2`.
    * `:fallback_synthesis` - When the loop hits `max_iterations` without
      `answer` being called and chunks have been accumulated, do one final
      tool-less LLM call to synthesize an answer from those chunks. Defaults
      to `true`. Set to `false` to leave `ctx.answer` as nil on
      max_iterations.
    * `:synthesizer` - Override the synthesis function used for the
      `max_iterations` fallback path. Receives `(messages, opts)` and must
      return `{:ok, text}` or `{:error, reason}`. When unset, the default
      synthesizer calls `:answer_llm` if set, otherwise `:controller_llm`.
      Setting `:synthesizer` directly bypasses both. Note: this only affects
      the fallback path. The `answer` tool rewrite always uses `:answer_llm`
      directly when set, regardless of `:synthesizer`.
  """
  @spec run(Context.t(), keyword()) :: {:ok, Context.t()}
  def run(%Context{} = ctx, opts \\ []) do
    opts = Arcana.Config.merge_app_opts(opts, :loop)

    tools = Keyword.get(opts, :tools) || Tools.default()
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    controller_llm = Keyword.get(opts, :controller_llm) || Arcana.Config.get(opts, :llm)
    answer_llm = Keyword.get(opts, :answer_llm)

    if is_nil(controller_llm) do
      raise ArgumentError,
            "Arcana.Loop.run/2 requires :controller_llm (or :llm) option, " <>
              "or set config :arcana, loop: [controller_llm: ...]"
    end

    # Force the resolved max_iterations into opts so the system prompt and
    # the loop see the same number, even when the caller didn't pass it.
    opts = Keyword.put(opts, :max_iterations, max_iterations)

    system_prompt = resolve_system_prompt(Keyword.get(opts, :system_prompt), opts)
    messages = build_initial_messages(ctx.question, system_prompt)

    start_metadata = %{
      question: ctx.question,
      max_iterations: max_iterations,
      tool_count: length(tools)
    }

    :telemetry.span([:arcana, :loop], start_metadata, fn ->
      {:ok, looped_ctx} =
        loop(
          %{ctx | messages: messages},
          tools,
          controller_llm,
          answer_llm,
          max_iterations,
          opts
        )

      final_ctx = maybe_synthesize_fallback(looped_ctx, controller_llm, answer_llm, opts)

      stop_metadata =
        Map.merge(start_metadata, %{
          iterations: final_ctx.iterations,
          terminated_by: final_ctx.terminated_by
        })

      {{:ok, final_ctx}, stop_metadata}
    end)
  end

  @doc """
  Runs a grounding analysis on the loop's answer against the accumulated
  chunks and stores the result in `ctx.grounding`.

  Reuses the `Arcana.Grounder` behaviour. By default uses
  `Arcana.Grounder.Hallmark`, which scores sentence-level
  faithfulness via Vectara HHEM through Bumblebee.

  ## Skipped cases

  Grounding is a no-op (`ctx.grounding` stays `nil`) when:

    * The loop terminated with `terminated_by: :error` (`ctx.error` is set)
    * `ctx.answer` is `nil`
    * `ctx.chunks` is empty — there's nothing to ground against

  ## Options

    * `:grounder` - Module implementing `Arcana.Grounder` or a
      3-arity function `(answer, chunks, opts) -> {:ok, result} | {:error, reason}`.
      Defaults to `Arcana.Grounder.Hallmark`.

  Any other options are passed through to the grounder, with `:question`
  added automatically from `ctx.question`.

  ## Example

      {:ok, ctx} =
        Arcana.Loop.new("What is a TARDIS?", repo: repo, collection: "doctor-who")
        |> Arcana.Loop.run(controller_llm: llm)

      ctx = Arcana.Loop.ground(ctx)

      ctx.grounding.score               # 0.0-1.0 faithfulness
      ctx.grounding.hallucinated_spans  # unsupported sentences
      ctx.grounding.faithful_spans      # supported sentences + chunk attribution

  Errors from the grounder are swallowed: if the grounder fails, `ctx.grounding`
  stays `nil` and the rest of the context is unchanged. Grounding is a
  nice-to-have annotation, not a fatal step.
  """
  @spec ground(Context.t(), keyword()) :: Context.t()
  def ground(ctx, opts \\ [])

  def ground(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx
  def ground(%Context{answer: nil} = ctx, _opts), do: ctx
  def ground(%Context{chunks: []} = ctx, _opts), do: ctx

  def ground(%Context{} = ctx, opts) do
    grounder = Keyword.get(opts, :grounder, Arcana.Grounder.Hallmark)

    start_metadata = %{
      question: ctx.question,
      grounder: grounder_name(grounder)
    }

    :telemetry.span([:arcana, :loop, :ground], start_metadata, fn ->
      grounder_opts = Keyword.merge(opts, question: ctx.question)

      grounding =
        case do_ground(grounder, ctx.answer, ctx.chunks, grounder_opts) do
          {:ok, result} -> enrich_with_tool_history(result, ctx.tool_history)
          {:error, _} -> nil
        end

      updated_ctx = %{ctx | grounding: grounding}

      stop_metadata = %{
        score: grounding && grounding.score,
        hallucinated_span_count: grounding && length(grounding.hallucinated_spans),
        faithful_span_count: grounding && length(grounding.faithful_spans)
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp grounder_name(grounder) when is_atom(grounder), do: grounder
  defp grounder_name(_grounder), do: :custom_function

  defp do_ground(grounder, answer, chunks, opts) when is_atom(grounder) do
    grounder.ground(answer, chunks, opts)
  end

  defp do_ground(grounder, answer, chunks, opts) when is_function(grounder, 3) do
    grounder.(answer, chunks, opts)
  end

  # Tool-call attribution (Agent GPA pattern): for each chunk_id that a
  # faithful/hallucinated span's source points at, look up which search
  # iteration first produced that chunk and annotate the source with
  # `:search_iteration` and `:search_query`. Sources whose chunk_id we
  # don't recognize get those keys as nil rather than crashing or being
  # dropped — defensive in case the grounder returns chunk IDs we don't
  # have history for.
  defp enrich_with_tool_history(%Arcana.Grounding.Result{} = result, tool_history) do
    index = build_chunk_id_index(tool_history)

    %{
      result
      | faithful_spans: Enum.map(result.faithful_spans, &enrich_span(&1, index)),
        hallucinated_spans: Enum.map(result.hallucinated_spans, &enrich_span(&1, index))
    }
  end

  defp build_chunk_id_index(tool_history) do
    # chunk_id -> %{iteration, query} for the first search entry that
    # returned this chunk. If the same chunk came back from multiple
    # searches, we record the earliest one.
    Enum.reduce(tool_history, %{}, fn entry, acc ->
      chunk_ids = Map.get(entry, :returned_chunk_ids, [])
      query = get_in(entry, [:args, :query]) || get_in(entry, [:args, "query"])

      Enum.reduce(chunk_ids, acc, fn chunk_id, inner ->
        Map.put_new(inner, chunk_id, %{
          iteration: entry.iteration,
          query: query
        })
      end)
    end)
  end

  defp enrich_span(%{sources: sources} = span, index) do
    enriched_sources = Enum.map(sources, &enrich_source(&1, index))
    %{span | sources: enriched_sources}
  end

  defp enrich_span(span, _index), do: span

  defp enrich_source(%{chunk_id: chunk_id} = source, index) do
    case Map.get(index, chunk_id) do
      nil ->
        source
        |> Map.put(:search_iteration, nil)
        |> Map.put(:search_query, nil)

      %{iteration: iteration, query: query} ->
        source
        |> Map.put(:search_iteration, iteration)
        |> Map.put(:search_query, query)
    end
  end

  defp enrich_source(source, _index), do: source

  # Graceful degradation: if the controller hit max_iterations without
  # calling `answer`, synthesize a final answer from the chunks we have.
  # Disable with `fallback_synthesis: false`. The synthesizer is a function
  # `(messages, opts) -> {:ok, text} | {:error, reason}`. The default
  # appends a "synthesize now" instruction and calls the controller LLM
  # without tools so it has to produce text.
  defp maybe_synthesize_fallback(%Context{} = ctx, controller_llm, answer_llm, opts) do
    cond do
      ctx.terminated_by != :max_iterations ->
        ctx

      not Keyword.get(opts, :fallback_synthesis, true) ->
        ctx

      ctx.chunks == [] ->
        ctx

      true ->
        synth_fn =
          Keyword.get(opts, :synthesizer) ||
            default_synthesizer(answer_llm || controller_llm)

        synthesis_messages = append_synthesis_request(ctx.messages)

        case synth_fn.(synthesis_messages, opts) do
          {:ok, text} -> %{ctx | answer: text, messages: synthesis_messages}
          {:error, _reason} -> ctx
        end
    end
  end

  defp default_synthesizer(controller_llm) do
    fn messages, opts ->
      case call_controller(controller_llm, messages, [], opts) do
        {:ok, %{text: text}} when is_binary(text) and text != "" -> {:ok, text}
        {:ok, _} -> {:error, :no_text_in_response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp append_synthesis_request(messages) do
    instruction =
      "You have run out of search budget. Synthesize the best answer you can " <>
        "from the chunks gathered above. Return the answer as plain text, no tool calls."

    ReqLLM.Context.append(messages, ReqLLM.Context.user(instruction))
  end

  defp loop(%Context{iterations: i} = ctx, _tools, _llm, _answer_llm, max, _opts) when i >= max do
    {:ok, %{ctx | terminated_by: :max_iterations}}
  end

  defp loop(%Context{} = ctx, tools, llm, answer_llm, max, opts) do
    iteration = ctx.iterations

    case call_controller(llm, ctx.messages, tools, opts) do
      {:ok, %{type: :final_answer, text: text}} ->
        {:ok,
         %{
           ctx
           | answer: text,
             terminated_by: :answered,
             iterations: iteration + 1,
             messages: append_assistant_text(ctx.messages, text)
         }}

      {:ok, %{type: :tool_calls, tool_calls: tool_calls} = classified} ->
        ctx_after_assistant = %{
          ctx
          | messages: append_assistant_with_tool_calls(ctx.messages, classified, tool_calls)
        }

        case execute_tool_calls(ctx_after_assistant, tool_calls, iteration, answer_llm, opts) do
          {:terminate, new_ctx} ->
            {:ok, %{new_ctx | iterations: iteration + 1}}

          {:continue, new_ctx} ->
            loop(%{new_ctx | iterations: iteration + 1}, tools, llm, answer_llm, max, opts)
        end

      {:error, reason} ->
        {:ok,
         %{
           ctx
           | terminated_by: :error,
             error: reason,
             iterations: iteration + 1
         }}
    end
  end

  defp execute_tool_calls(ctx, tool_calls, iteration, answer_llm, opts) do
    Enum.reduce_while(tool_calls, {:continue, ctx}, fn call, {_, acc_ctx} ->
      args = atomize_keys(call.arguments)

      case Tools.execute(acc_ctx, call.name, args, opts) do
        {:terminate, new_ctx, reason, draft} ->
          final_text = maybe_rewrite_with_answerer(new_ctx, draft, reason, answer_llm, opts)

          new_ctx =
            new_ctx
            |> record_history(
              call.name,
              args,
              iteration,
              summarize_terminate(reason, final_text),
              %{}
            )
            |> Map.put(:answer, final_text)
            |> Map.put(:terminated_by, reason)
            |> Map.update!(:messages, &append_tool_result(&1, call, final_text))

          {:halt, {:terminate, new_ctx}}

        {:continue, new_ctx, summary, meta} ->
          new_ctx =
            new_ctx
            |> record_history(call.name, args, iteration, summary, meta)
            |> Map.update!(:messages, &append_tool_result(&1, call, summary))

          {:cont, {:continue, new_ctx}}
      end
    end)
  end

  # When :answer_llm is set and the controller calls the `answer` tool, hand
  # off to the answerer for the final user-facing text. The answerer sees the
  # full conversation (including the controller's draft answer call) plus a
  # "produce the final answer" instruction. Falls back to the controller's
  # draft text if the answerer errors or returns nothing useful.
  #
  # `give_up` is intentionally not rewritten: it's a failure signal, not
  # answer prose, and dressing it up just makes the failure mode opaque.
  defp maybe_rewrite_with_answerer(_ctx, draft, _reason, nil, _opts), do: draft
  defp maybe_rewrite_with_answerer(_ctx, draft, :gave_up, _answer_llm, _opts), do: draft

  defp maybe_rewrite_with_answerer(ctx, draft, :answered, answer_llm, opts) do
    rewrite_messages = append_answer_request(ctx.messages)

    case call_controller(answer_llm, rewrite_messages, [], opts) do
      {:ok, %{text: text}} when is_binary(text) and text != "" -> text
      _ -> draft
    end
  end

  defp append_answer_request(messages) do
    instruction =
      "The research is complete. Based on the chunks gathered above, write the " <>
        "final user-facing answer to the original question. Return plain text only, " <>
        "no tool calls."

    ReqLLM.Context.append(messages, ReqLLM.Context.user(instruction))
  end

  defp record_history(%Context{tool_history: history} = ctx, name, args, iteration, summary, meta) do
    entry =
      %{
        # to_existing_atom so a hallucinated or custom tool name can't
        # leak fresh atoms into the global table. Known default tools
        # (search, answer, give_up) are compile-time atoms; unknown
        # names stay as strings in the history for debugging.
        tool: safe_tool_atom(name),
        args: args,
        iteration: iteration,
        summary: summary,
        returned_chunk_ids: Map.get(meta, :returned_chunk_ids, [])
      }

    # Append is O(n) but `tool_history` is bounded by `:max_iterations`
    # (default 10), so the cumulative cost is trivial and the natural
    # iteration order matters for downstream display.
    new_history = history ++ [entry]

    # Per-tool-call telemetry so dashboards (or any consumer) can render
    # a live trace as the loop unfolds rather than waiting for the
    # whole run to finish. The metadata mirrors the entry shape exactly
    # so handlers can use it directly.
    :telemetry.execute(
      [:arcana, :loop, :tool_call],
      %{count: 1, history_size: length(new_history)},
      entry
    )

    %{ctx | tool_history: new_history}
  end

  defp safe_tool_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp summarize_terminate(:answered, _answer), do: "Answered."
  defp summarize_terminate(:gave_up, answer), do: "Gave up: #{answer}"

  defp atomize_keys(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  defp atomize_keys(other), do: other

  defp resolve_system_prompt(nil, opts), do: SystemPrompt.default(opts)
  defp resolve_system_prompt(text, _opts) when is_binary(text), do: text
  defp resolve_system_prompt(fun, opts) when is_function(fun, 1), do: fun.(opts)

  defp build_initial_messages(question, system_prompt) do
    ReqLLM.Context.new([
      ReqLLM.Context.system(system_prompt),
      ReqLLM.Context.user(question)
    ])
  end

  defp call_controller(llm, messages, tools, opts) when is_function(llm, 3) do
    llm.(messages, tools, opts)
  end

  defp call_controller({model, llm_opts}, messages, tools, opts) do
    call_controller(model, messages, tools, Keyword.merge(llm_opts, opts))
  end

  defp call_controller(llm, messages, tools, opts) do
    reqllm_opts =
      opts
      |> Keyword.take([:api_key, :temperature, :max_tokens, :provider_options])
      |> Keyword.put(:tools, tools)

    case ReqLLM.generate_text(llm, messages, reqllm_opts) do
      {:ok, response} -> {:ok, ReqLLM.Response.classify(response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_assistant_text(messages, text) do
    ReqLLM.Context.append(messages, ReqLLM.Context.assistant(text))
  end

  defp append_assistant_with_tool_calls(messages, classified, tool_calls) do
    text = classified.text || ""

    content =
      if text != "", do: [ContentPart.text(text)], else: []

    canonical_tool_calls = Enum.map(tool_calls, &to_canonical_tool_call/1)

    msg = %ReqLLM.Message{
      role: :assistant,
      content: content,
      name: nil,
      tool_call_id: nil,
      tool_calls: canonical_tool_calls,
      metadata: %{},
      reasoning_details: nil
    }

    ReqLLM.Context.append(messages, msg)
  end

  # ReqLLM.Response.classify/1 normalizes every tool_call to a plain
  # %{id, name, arguments} map before returning, so that's the only
  # shape we'll ever see here.
  defp to_canonical_tool_call(%{id: id, name: name, arguments: args}) do
    args_json =
      cond do
        is_binary(args) -> args
        is_map(args) -> Jason.encode!(args)
        true -> "{}"
      end

    ReqLLM.ToolCall.new(id, name, args_json)
  end

  defp append_tool_result(messages, call, result_text) do
    msg = ReqLLM.Context.tool_result_message(call.name, call.id, result_text)
    ReqLLM.Context.append(messages, msg)
  end
end
