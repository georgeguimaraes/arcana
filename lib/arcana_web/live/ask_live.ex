defmodule ArcanaWeb.AskLive do
  @moduledoc """
  LiveView for asking questions about documents in Arcana.
  """
  use Phoenix.LiveView

  import Ecto.Query
  import ArcanaWeb.DashboardComponents

  alias Arcana.Document
  alias Arcana.Graph.Entity
  alias ArcanaWeb.ChunkResultsComponent

  # Form param names for the Pipeline tab's optional steps. Tracked in
  # socket assigns so the all/none toggle can update them server-side
  # rather than reaching into the DOM with inline JS.
  @pipeline_step_keys ~w(use_gate use_rewrite use_expand use_decompose use_reason self_correct use_rerank use_ground)

  # Groups the pipeline steps into the three phases of the Singh taxonomy's
  # Modular RAG: query preparation, retrieval, and answer. Used by the
  # per-phase "all / none" toggles on the Pipeline UI.
  @pipeline_step_groups %{
    "query" => ~w(use_gate use_rewrite use_expand use_decompose),
    "retrieval" => ~w(use_reason use_rerank),
    "answer" => ~w(self_correct use_ground)
  }

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       ask_sub_tab: :advanced,
       ask_question: "",
       ask_running: false,
       ask_context: nil,
       ask_error: nil,
       stats: nil,
       collections: [],
       graph_search: true,
       selected_collections: [],
       graph_context_expanded: true,
       llm_select: false,
       pipeline_step: nil,
       pipeline_steps: Map.new(@pipeline_step_keys, &{&1, false}),
       loop_live_history: [],
       loop_phase: :idle,
       trace_history: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    sub_tab = parse_sub_tab(params["sub_tab"])
    sub_tab_changed? = sub_tab != socket.assigns.ask_sub_tab
    # LLM collection select only makes sense on the Pipeline sub-tab
    llm_select = if sub_tab == :pipeline, do: socket.assigns.llm_select, else: false

    socket =
      socket
      |> assign(ask_sub_tab: sub_tab, llm_select: llm_select)
      |> maybe_reset_ask_state(sub_tab_changed?)
      |> maybe_load_data()

    {:noreply, socket}
  end

  # Stats and collections only need to load once per LiveView session.
  # Sub-tab switches re-enter handle_params/3 via push_patch but don't
  # need to re-query the DB.
  defp maybe_load_data(%{assigns: %{stats: nil}} = socket), do: load_data(socket)
  defp maybe_load_data(socket), do: socket

  # Switching sub-tabs swaps in a different retrieval strategy, so any
  # previously rendered context, error, or pipeline progress label belongs
  # to the old strategy and would be confusing to leave visible.
  defp maybe_reset_ask_state(socket, false), do: socket

  defp maybe_reset_ask_state(socket, true) do
    assign(socket,
      ask_context: nil,
      ask_error: nil,
      pipeline_step: nil,
      loop_live_history: [],
      loop_phase: :idle,
      trace_history: []
    )
  end

  defp parse_sub_tab("advanced"), do: :advanced
  defp parse_sub_tab("pipeline"), do: :pipeline
  defp parse_sub_tab("loop"), do: :loop
  # Any other value (including nil for /arcana/ask with no segment, or an
  # unknown sub-tab name) falls back to the default landing.
  defp parse_sub_tab(_), do: :advanced

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: load_collections_with_graph_status(repo))
  end

  defp load_collections_with_graph_status(repo) do
    collections = load_collections(repo)

    # Get entity counts per collection
    entity_counts =
      repo.all(
        from(e in Entity,
          group_by: e.collection_id,
          select: {e.collection_id, count(e.id)}
        )
      )
      |> Map.new()

    Enum.map(collections, fn c ->
      entity_count = Map.get(entity_counts, c.id, 0)
      Map.put(c, :graph_enabled, entity_count > 0)
    end)
  end

  defp selected_graph_enabled?(collections, selected) do
    case selected do
      [] -> false
      names -> Enum.any?(collections, &(&1.name in names and &1[:graph_enabled]))
    end
  end

  @impl true
  def handle_event("ask_submit", params, socket) do
    question = params["question"] || ""

    case {Application.get_env(:arcana, :llm), question} do
      {nil, _} ->
        {:noreply,
         assign(socket,
           ask_error: "No LLM configured. Set :arcana, :llm in your config.",
           ask_running: false
         )}

      {_, ""} ->
        {:noreply, assign(socket, ask_error: "Please enter a question")}

      {llm, question} ->
        socket =
          assign(socket,
            ask_running: true,
            ask_error: nil,
            ask_question: question,
            ask_context: nil,
            loop_live_history: [],
            loop_phase: :idle,
            trace_history: []
          )

        start_ask_task(socket, params, llm, question)
        {:noreply, socket}
    end
  end

  def handle_event("ask_clear", _params, socket) do
    {:noreply,
     assign(socket,
       ask_context: nil,
       ask_error: nil,
       ask_question: "",
       loop_live_history: [],
       loop_phase: :idle,
       trace_history: []
     )}
  end

  def handle_event("ask_switch_sub_tab", %{"sub_tab" => sub_tab}, socket) do
    # push_patch to the corresponding URL so the sub-tab selection is
    # shareable and survives page reloads. handle_params/3 will pick
    # up the new :sub_tab param and update the assigns.
    {:noreply, push_patch(socket, to: "/arcana/ask/#{sub_tab}")}
  end

  def handle_event("form_changed", params, socket) do
    selected = params["collections"] || []
    pipeline_steps = Map.new(@pipeline_step_keys, &{&1, params[&1] == "true"})
    # Carry the textarea content forward on every form-change so a
    # checkbox click (collections, pipeline steps) doesn't blow away
    # what the user typed in the question box.
    question = params["question"] || socket.assigns.ask_question

    {:noreply,
     assign(socket,
       selected_collections: selected,
       pipeline_steps: pipeline_steps,
       ask_question: question
     )}
  end

  def handle_event("toggle_graph_context", _params, socket) do
    {:noreply, assign(socket, graph_context_expanded: !socket.assigns.graph_context_expanded)}
  end

  def handle_event("toggle_llm_select", _params, socket) do
    {:noreply, assign(socket, llm_select: !socket.assigns.llm_select)}
  end

  def handle_event("set_pipeline_steps", %{"mode" => mode} = params, socket) do
    enabled? = mode == "all"

    keys =
      case Map.get(params, "group") do
        nil -> @pipeline_step_keys
        group -> Map.get(@pipeline_step_groups, group, [])
      end

    steps =
      Enum.reduce(keys, socket.assigns.pipeline_steps, fn key, acc ->
        Map.put(acc, key, enabled?)
      end)

    {:noreply, assign(socket, pipeline_steps: steps)}
  end

  defp ask_loading_label(:advanced, _step, _phase), do: "Generating answer..."

  defp ask_loading_label(:loop, _step, :grounding),
    do: "Grounding answer against retrieved chunks..."

  defp ask_loading_label(:loop, _step, _phase), do: "Running agent loop..."
  defp ask_loading_label(:pipeline, step, _phase), do: step || "Running pipeline..."

  # Renders an answer as markdown via MDEx. MDEx is an optional dep
  # (see mix.exs) because the dashboard itself is optional. When it's
  # missing, fall back to a minimal plain-text-to-html that preserves
  # paragraph + line breaks (double newlines → <p>, single newlines →
  # <br>) instead of collapsing the whole answer into one wall of text.
  #
  # MDEx's `:sanitize` enables ammonia-based HTML sanitization so any
  # raw HTML the LLM emits gets scrubbed (the LLM is untrusted input).
  # The fallback path also escapes HTML so it's safe to render.
  defp render_markdown_answer(text) when is_binary(text) do
    trimmed = String.trim(text)

    if Code.ensure_loaded?(MDEx) do
      Phoenix.HTML.raw(MDEx.to_html!(trimmed, sanitize: []))
    else
      plain_text_to_html(trimmed)
    end
  end

  defp render_markdown_answer(_), do: ""

  defp plain_text_to_html(text) do
    paragraphs =
      text
      |> String.split(~r/\n{2,}/)
      |> Enum.map_join("", fn paragraph ->
        body =
          paragraph
          |> String.split("\n")
          |> Enum.map_join("<br>", fn line ->
            line
            |> Phoenix.HTML.html_escape()
            |> Phoenix.HTML.safe_to_string()
          end)

        "<p>#{body}</p>"
      end)

    Phoenix.HTML.raw(paragraphs)
  end

  # Resolves which LLM each role uses, mirroring the lookup chain inside
  # Arcana.Loop.run/2:
  #   controller_llm = config :arcana, :loop, :controller_llm || :arcana, :llm
  #   answer_llm     = config :arcana, :loop, :answer_llm (nil → uses controller text)
  #   fallback       = answer_llm || controller_llm
  defp loop_llm_roles do
    loop_opts = Application.get_env(:arcana, :loop, [])
    base_llm = Application.get_env(:arcana, :llm)

    controller = Keyword.get(loop_opts, :controller_llm) || base_llm
    answer = Keyword.get(loop_opts, :answer_llm)

    %{
      controller: format_llm_spec(controller),
      answer: format_llm_spec(answer),
      fallback: format_llm_spec(answer || controller)
    }
  end

  defp format_llm_spec(nil), do: nil
  defp format_llm_spec(fun) when is_function(fun), do: "<function/1>"
  defp format_llm_spec({model, _opts}) when is_binary(model), do: model
  defp format_llm_spec({model, _opts}) when is_atom(model), do: Atom.to_string(model)
  defp format_llm_spec(model) when is_binary(model), do: model
  defp format_llm_spec(model) when is_atom(model), do: Atom.to_string(model)
  defp format_llm_spec(other), do: inspect(other, limit: 1)

  defp start_ask_task(socket, params, llm, question) do
    repo = socket.assigns.repo
    sub_tab = params["sub_tab"] || "advanced"
    selected_collections = params["collections"] || []
    parent = self()

    Arcana.TaskSupervisor.start_child(fn ->
      handler_id = "pipeline-progress-#{inspect(parent)}"
      trace_handler_id = "trace-progress-#{inspect(parent)}"
      loop_handler_id = "loop-progress-#{inspect(parent)}"

      graph_enabled = params["graph_search"] == "true"

      pipeline_steps = [
        :gate,
        :rewrite,
        :expand,
        :decompose,
        :select,
        :search,
        :reason,
        :self_correct,
        :rerank,
        :answer,
        :ground
      ]

      # Pipeline progress label events (the old "Running X..." text that
      # updates the spinner label).
      label_events =
        Enum.map(pipeline_steps, &[:arcana, :pipeline, &1, :start]) ++
          [[:arcana, :graph, :search, :start]]

      :telemetry.attach_many(
        handler_id,
        label_events,
        fn
          [:arcana, :graph, :search, :start], _measurements, _metadata, _config ->
            send(parent, {:pipeline_progress, "Searching with graph connections..."})

          [:arcana, :pipeline, step, :start], _measurements, _metadata, _config ->
            label =
              if step == :search and graph_enabled,
                do: "Searching with graph connections...",
                else: pipeline_step_label(step)

            if label, do: send(parent, {:pipeline_progress, label})
        end,
        nil
      )

      # Trace events for the live step-by-step panel. Every sub-tab
      # subscribes, the handler normalizes the event path to a
      # `{:trace_step_start, atom}` / `{:trace_step_stop, atom, ms, meta}`
      # tuple. Pipeline and Advanced both flow through this pathway.
      trace_events =
        Enum.flat_map(pipeline_steps, fn step ->
          [
            [:arcana, :pipeline, step, :start],
            [:arcana, :pipeline, step, :stop]
          ]
        end) ++
          [
            [:arcana, :search, :start],
            [:arcana, :search, :stop],
            [:arcana, :graph, :search, :start],
            [:arcana, :graph, :search, :stop],
            [:arcana, :llm, :complete, :start],
            [:arcana, :llm, :complete, :stop]
          ]

      :telemetry.attach_many(
        trace_handler_id,
        trace_events,
        fn event, measurements, metadata, _config ->
          case {event, measurements} do
            {[:arcana, :pipeline, step, :start], _} ->
              send(parent, {:trace_step_start, step})

            {[:arcana, :pipeline, step, :stop], %{duration: d}} ->
              send(parent, {:trace_step_stop, step, native_to_ms(d), metadata})

            {[:arcana, :search, :start], _} ->
              send(parent, {:trace_step_start, :search})

            {[:arcana, :search, :stop], %{duration: d}} ->
              send(parent, {:trace_step_stop, :search, native_to_ms(d), metadata})

            {[:arcana, :graph, :search, :start], _} ->
              send(parent, {:trace_step_start, :graph_search})

            {[:arcana, :graph, :search, :stop], %{duration: d}} ->
              send(parent, {:trace_step_stop, :graph_search, native_to_ms(d), metadata})

            {[:arcana, :llm, :complete, :start], _} ->
              send(parent, {:trace_step_start, :llm_complete})

            {[:arcana, :llm, :complete, :stop], %{duration: d}} ->
              send(parent, {:trace_step_stop, :llm_complete, native_to_ms(d), metadata})

            _ ->
              :ok
          end
        end,
        nil
      )

      # Per-tool-call telemetry for the Loop sub-tab. Each event carries
      # the same shape as a tool_history entry, so the LV can render
      # the live trace incrementally as the loop unfolds.
      :telemetry.attach_many(
        loop_handler_id,
        [
          [:arcana, :loop, :tool_call],
          [:arcana, :loop, :ground, :start],
          [:arcana, :loop, :ground, :stop]
        ],
        fn
          [:arcana, :loop, :tool_call], _measurements, metadata, _config ->
            send(parent, {:loop_progress, metadata})

          [:arcana, :loop, :ground, :start], _measurements, _metadata, _config ->
            send(parent, {:loop_phase, :grounding})

          [:arcana, :loop, :ground, :stop], _measurements, _metadata, _config ->
            send(parent, {:loop_phase, :idle})
        end,
        nil
      )

      result =
        run_ask(
          sub_tab,
          question,
          repo,
          llm,
          socket.assigns.collections,
          params,
          selected_collections
        )

      :telemetry.detach(handler_id)
      :telemetry.detach(trace_handler_id)
      :telemetry.detach(loop_handler_id)
      send(parent, {:ask_complete, result})
    end)
  end

  defp native_to_ms(duration) do
    System.convert_time_unit(duration, :native, :millisecond)
  end

  defp run_ask("advanced", question, repo, llm, _all_collections, params, selected_collections) do
    run_advanced_ask(question, repo, llm, selected_collections, params)
  end

  defp run_ask("loop", question, repo, llm, _all_collections, params, selected_collections) do
    run_loop_ask(question, repo, llm, selected_collections, params)
  end

  defp run_ask("pipeline", question, repo, llm, all_collections, params, selected_collections) do
    run_pipeline_ask(
      question,
      repo,
      llm,
      all_collections,
      collections: selected_collections,
      use_llm_select: params["llm_select"] == "true",
      use_gate: params["use_gate"] == "true",
      use_rewrite: params["use_rewrite"] == "true",
      use_expand: params["use_expand"] == "true",
      use_decompose: params["use_decompose"] == "true",
      use_reason: params["use_reason"] == "true",
      use_rerank: params["use_rerank"] == "true",
      use_ground: params["use_ground"] == "true",
      self_correct: params["self_correct"] == "true",
      hallucinate_demo: params["answer_mode"] == "hallucinate",
      graph: params["graph_search"] == "true"
    )
  end

  @impl true
  def handle_info({:pipeline_progress, step}, socket) do
    {:noreply, assign(socket, pipeline_step: step)}
  end

  def handle_info({:loop_progress, entry}, socket) do
    # Append, not prepend: render order matches iteration order so the
    # newest entry visually lands at the bottom of the trace.
    {:noreply, assign(socket, loop_live_history: socket.assigns.loop_live_history ++ [entry])}
  end

  def handle_info({:loop_phase, phase}, socket) do
    {:noreply, assign(socket, loop_phase: phase)}
  end

  def handle_info({:trace_step_start, step}, socket) do
    entry = %{step: step, status: :running, duration_ms: nil, meta: nil}

    {:noreply, assign(socket, trace_history: socket.assigns.trace_history ++ [entry])}
  end

  def handle_info({:trace_step_stop, step, duration_ms, metadata}, socket) do
    history =
      socket.assigns.trace_history
      |> Enum.reverse()
      |> mark_step_done(step, duration_ms, metadata)
      |> Enum.reverse()

    {:noreply, assign(socket, trace_history: history)}
  end

  def handle_info({:ask_complete, result}, socket) do
    socket =
      case result do
        {:ok, ctx} ->
          ctx = Map.put(ctx, :document_titles, load_document_titles(ctx, socket.assigns.repo))
          assign(socket, ask_running: false, ask_context: ctx, ask_error: nil, pipeline_step: nil)

        {:error, reason} ->
          assign(socket, ask_running: false, ask_error: inspect(reason), pipeline_step: nil)
      end

    {:noreply, socket}
  end

  # Batch-loads document titles for every chunk in the result. All three
  # sub-tabs put chunks under :results, so one helper covers everything.
  # Falls back to an empty map on any error — the component already
  # degrades to a shortened UUID when a title is missing.
  defp load_document_titles(%{results: chunks}, repo)
       when is_list(chunks) and not is_nil(repo) do
    ids =
      chunks
      |> Enum.map(&Map.get(&1, :document_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        try do
          from(d in Document, where: d.id in ^ids, select: {d.id, d.metadata})
          |> repo.all()
          |> Map.new(fn {id, metadata} -> {id, extract_title(metadata)} end)
        rescue
          _ -> %{}
        end
    end
  end

  defp load_document_titles(_ctx, _repo), do: %{}

  defp extract_title(nil), do: nil

  defp extract_title(metadata) when is_map(metadata) do
    Map.get(metadata, "title") || Map.get(metadata, :title)
  end

  defp extract_title(_), do: nil

  # Update the most recent :running entry that matches `step`. Walking
  # the reversed list and replacing the first match is correct because
  # pipeline steps are sequential — the latest :running entry for a
  # given step name is always the one that just stopped.
  defp mark_step_done(
         [%{step: step, status: :running} = entry | rest],
         step,
         duration_ms,
         metadata
       ) do
    [%{entry | status: :done, duration_ms: duration_ms, meta: metadata} | rest]
  end

  defp mark_step_done([head | rest], step, duration_ms, metadata) do
    [head | mark_step_done(rest, step, duration_ms, metadata)]
  end

  defp mark_step_done([], _step, _duration_ms, _metadata), do: []

  defp run_loop_ask(question, repo, llm, selected_collections, params) do
    max_iterations =
      case Integer.parse(params["max_iterations"] || "10") do
        {n, _} when n > 0 -> n
        _ -> 10
      end

    chunk_cap =
      case Integer.parse(params["chunk_cap"] || "50") do
        {n, _} when n > 0 -> n
        _ -> 50
      end

    controller_temperature = parse_temperature(params["controller_temperature"])
    answer_temperature = parse_temperature(params["answer_temperature"])
    fallback_temperature = parse_temperature(params["fallback_temperature"])

    run_ground? = params["use_ground_loop"] == "true"
    ground_opts = [grounder: Arcana.Grounder.LLMJudge, judge_model: llm]

    new_opts =
      [repo: repo]
      |> maybe_put_collection_opt(selected_collections)

    run_opts =
      [
        controller_llm: llm,
        max_iterations: max_iterations,
        chunk_cap: chunk_cap
      ]
      |> maybe_put(:controller_temperature, controller_temperature)
      |> maybe_put(:answer_temperature, answer_temperature)
      |> maybe_put(:fallback_temperature, fallback_temperature)

    ctx = Arcana.Loop.new(question, new_opts)
    runner = loop_runner()

    with {:ok, ctx} <- runner.(ctx, run_opts) do
      ctx = if run_ground?, do: Arcana.Loop.ground(ctx, ground_opts), else: ctx
      {:ok, format_loop_result(ctx, question)}
    end
  rescue
    e ->
      require Logger
      Logger.error(Exception.format(:error, e, __STACKTRACE__))
      {:error, Exception.message(e)}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_temperature(nil), do: nil
  defp parse_temperature(""), do: nil

  defp parse_temperature(str) when is_binary(str) do
    case Float.parse(str) do
      {t, _} when t >= 0 and t <= 2 -> t
      _ -> nil
    end
  end

  # Hook for tests to stub out Loop execution. Defaults to the real Loop.run/2.
  defp loop_runner do
    Application.get_env(:arcana, :loop_runner) || (&Arcana.Loop.run/2)
  end

  # Arcana.Loop.new/2 (and Arcana.search, Arcana.ask, Arcana.Pipeline.new)
  # all normalize `:collection` and `:collections` to the same internal
  # representation, so we can always pass the plural form and let the
  # library sort it out.
  defp maybe_put_collection_opt(opts, []), do: opts
  defp maybe_put_collection_opt(opts, list), do: Keyword.put(opts, :collections, list)

  defp format_loop_result(%Arcana.Loop.Context{} = ctx, question) do
    %{
      result_type: :loop,
      question: question,
      answer: ctx.answer,
      tool_history: ctx.tool_history,
      terminated_by: ctx.terminated_by,
      iterations: ctx.iterations,
      chunks: ctx.chunks,
      grounding: ctx.grounding,
      # Mirror the Pipeline result shape so existing result sections
      # (grounding, chunks) can reuse the same rendering. The extras are
      # what drives the agent trace view.
      results: ctx.chunks,
      expanded_query: nil,
      sub_questions: nil,
      selected_collections: nil
    }
  end

  defp run_advanced_ask(question, repo, llm, selected_collections, params) do
    graph = params["graph_search"] == "true"

    opts =
      [repo: repo, llm: llm, graph: graph]
      |> maybe_put_collection_opt(selected_collections)

    case Arcana.ask(question, opts) do
      {:ok, answer, results} ->
        # Build a context-like struct for consistent UI display
        {:ok,
         %{
           question: question,
           answer: answer,
           results: results,
           expanded_query: nil,
           sub_questions: nil,
           selected_collections:
             if(selected_collections == [], do: nil, else: selected_collections)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_pipeline_ask(question, repo, llm, all_collections, opts) do
    alias Arcana.Pipeline

    all_collection_names = Enum.map(all_collections, & &1.name)
    search_opts = build_search_opts(opts, all_collection_names)

    Pipeline.new(question, repo: repo, llm: llm)
    |> maybe_gate(opts)
    |> maybe_rewrite(opts)
    |> maybe_select(opts, all_collection_names)
    |> maybe_expand(opts)
    |> maybe_decompose(opts)
    |> Pipeline.search(search_opts)
    |> maybe_reason(opts)
    |> maybe_rerank(opts)
    |> maybe_answer_with_hallucinations(opts)
    |> maybe_ground(opts)
    |> format_pipeline_result(question)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_gate(ctx, opts) do
    if Keyword.get(opts, :use_gate, false), do: Arcana.Pipeline.gate(ctx), else: ctx
  end

  defp maybe_rewrite(ctx, opts) do
    if Keyword.get(opts, :use_rewrite, false), do: Arcana.Pipeline.rewrite(ctx), else: ctx
  end

  defp maybe_select(ctx, opts, all_collection_names) do
    if Keyword.get(opts, :use_llm_select, false) and length(all_collection_names) > 1 do
      Arcana.Pipeline.select(ctx, collections: all_collection_names)
    else
      ctx
    end
  end

  defp maybe_expand(ctx, opts) do
    if Keyword.get(opts, :use_expand, false), do: Arcana.Pipeline.expand(ctx), else: ctx
  end

  defp maybe_decompose(ctx, opts) do
    if Keyword.get(opts, :use_decompose, false), do: Arcana.Pipeline.decompose(ctx), else: ctx
  end

  defp maybe_reason(ctx, opts) do
    if Keyword.get(opts, :use_reason, false), do: Arcana.Pipeline.reason(ctx), else: ctx
  end

  defp maybe_rerank(ctx, opts) do
    # Use the local CrossEncoder reranker for the dashboard: it reorders
    # without filtering, which matches the UI copy ("Cross-encoder
    # rescoring") and avoids the LLM reranker's aggressive threshold that
    # can drop every chunk on the demo questions. Passing :top_k bypasses
    # the reranker's default threshold=0.0 filter since cross-encoder
    # logits can land entirely negative on broad questions.
    if Keyword.get(opts, :use_rerank, false) do
      Arcana.Pipeline.rerank(ctx,
        reranker: Arcana.Reranker.CrossEncoder,
        top_k: 30
      )
    else
      ctx
    end
  end

  defp maybe_answer_with_hallucinations(ctx, opts) do
    if Keyword.get(opts, :hallucinate_demo, false) do
      Arcana.Pipeline.answer(ctx, prompt: &hallucination_demo_prompt/2)
    else
      Arcana.Pipeline.answer(ctx)
    end
  end

  defp hallucination_demo_prompt(question, chunks) do
    reference_material =
      chunks
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, i} -> "[#{i}] #{chunk.text}" end)

    """
    Context:
    #{reference_material}

    Question: "#{question}"

    Answer the question using the context above, but deliberately slip in 1-2 plausible-sounding statements that are NOT supported by the context. These fabricated facts should blend naturally into the answer. Do not flag or mark which statements are made up.
    """
  end

  defp maybe_ground(ctx, opts) do
    # Pipeline grounding uses default Hallmark. HallmarkServing now
    # takes the top K reranked chunks (default 5), concats them into
    # one context, and scores each sentence against that. Synthesis
    # sentences that need evidence from multiple chunks land correctly
    # because the top-K concat preserves the full combined context.
    # Falls back to per-chunk max if the concat would exceed HHEM's
    # input window.
    if Keyword.get(opts, :use_ground, false) do
      Arcana.Pipeline.ground(ctx)
    else
      ctx
    end
  end

  defp build_search_opts(opts, all_collection_names) do
    base = [
      self_correct: Keyword.get(opts, :self_correct, false),
      graph: Keyword.get(opts, :graph, false)
    ]

    use_llm_select = Keyword.get(opts, :use_llm_select, false)

    if use_llm_select and length(all_collection_names) > 1 do
      base
    else
      add_collection_opts(base, Keyword.get(opts, :collections, []))
    end
  end

  defp add_collection_opts(opts, []), do: opts
  defp add_collection_opts(opts, list), do: Keyword.put(opts, :collections, list)

  defp format_pipeline_result(%{error: error}, _question) when not is_nil(error) do
    {:error, error}
  end

  defp format_pipeline_result(ctx, question) do
    # Flatten chunks from nested results to match simple mode format
    all_chunks =
      (ctx.results || [])
      |> Enum.flat_map(fn
        %{chunks: chunks} -> chunks
        chunk -> [chunk]
      end)
      |> Enum.uniq_by(& &1.id)

    graph_sourced_count =
      Enum.count(all_chunks, fn c ->
        sources = Map.get(c, :graph_sources) || []
        sources != []
      end)

    rerank_scores = Map.get(ctx, :rerank_scores) || %{}

    {:ok,
     %{
       question: question,
       answer: ctx.answer,
       results: all_chunks,
       retrieved_count: length(all_chunks),
       graph_sourced_count: graph_sourced_count,
       rewritten_query: ctx.rewritten_query,
       expanded_query: ctx.expanded_query,
       sub_questions: ctx.sub_questions,
       skip_retrieval: ctx.skip_retrieval,
       gate_reasoning: ctx.gate_reasoning,
       reason_iterations: ctx.reason_iterations,
       queries_tried: ctx.queries_tried,
       correction_count: ctx.correction_count,
       corrections: ctx.corrections,
       rerank_scores: rerank_scores,
       rerank_kept: map_size(rerank_scores),
       selected_collections: ctx.collections,
       grounding: ctx.grounding
     }}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:ask}>
      <div class="arcana-ask">
        <h2>Ask</h2>
        <p class="arcana-tab-description">
          Send a question through one of three retrieval strategies.
        </p>

        <div class="arcana-ask-sub-tab-nav">
          <button
            type="button"
            class={"arcana-ask-sub-tab #{if @ask_sub_tab == :advanced, do: "active", else: ""}"}
            phx-click="ask_switch_sub_tab"
            phx-value-sub_tab="advanced"
          >
            Advanced
          </button>
          <button
            type="button"
            class={"arcana-ask-sub-tab #{if @ask_sub_tab == :pipeline, do: "active", else: ""}"}
            phx-click="ask_switch_sub_tab"
            phx-value-sub_tab="pipeline"
          >
            Pipeline
          </button>
          <button
            type="button"
            class={"arcana-ask-sub-tab #{if @ask_sub_tab == :loop, do: "active", else: ""}"}
            phx-click="ask_switch_sub_tab"
            phx-value-sub_tab="loop"
          >
            Loop
          </button>
        </div>

        <p class="arcana-sub-tab-description">
          <%= case @ask_sub_tab do %>
            <% :advanced -> %>
              <code>Arcana.ask/2</code> — one call with sensible defaults. Query rewriting,
              hybrid search, reranking, optional graph fusion.
            <% :pipeline -> %>
              <code>Arcana.Pipeline</code> — Modular RAG. Compose the steps yourself,
              toggle each one on or off below.
            <% :loop -> %>
              <code>Arcana.Loop</code> — Agentic RAG. The LLM picks tools each turn
              until it can answer or hits the iteration cap.
          <% end %>
        </p>

        <%= if @ask_error do %>
          <div class="arcana-eval-message error">
            <%= @ask_error %>
          </div>
        <% end %>

        <form id="ask-form" phx-submit="ask_submit" phx-change="form_changed" class="arcana-ask-form">
          <input type="hidden" name="sub_tab" value={@ask_sub_tab} />

          <div class="arcana-ask-input">
            <textarea
              name="question"
              id="ask-question"
              placeholder="Ask a question about your documents..."
              rows="3"
              phx-hook="CmdEnterSubmit"
              disabled={@ask_running}
            ><%= @ask_question %></textarea>

            <%= if @ask_sub_tab == :advanced and selected_graph_enabled?(@collections, @selected_collections) do %>
              <label class="arcana-deep-search-toggle">
                <input
                  type="checkbox"
                  name="graph_search"
                  value="true"
                  checked={@graph_search}
                  disabled={@ask_running}
                />
                <span>Graph-Assisted</span>
                <small>Find results through entity relationships</small>
              </label>
            <% end %>
          </div>

          <div class="arcana-ask-collections">
            <label>Collections</label>
            <%= if @ask_sub_tab == :pipeline and length(@collections) > 1 do %>
              <div class="arcana-llm-select-toggle">
                <label class="arcana-checkbox-label">
                  <input
                    type="checkbox"
                    name="llm_select"
                    value="true"
                    checked={@llm_select}
                    disabled={@ask_running}
                    phx-click="toggle_llm_select"
                  />
                  <span>Let LLM select automatically</span>
                  <small>LLM will choose the most relevant collection(s) based on your question</small>
                </label>
              </div>
            <% end %>
            <%= if not @llm_select do %>
              <div class="arcana-collection-checkboxes">
                <%= for coll <- @collections do %>
                  <label class="arcana-collection-check">
                    <input
                      type="checkbox"
                      name="collections[]"
                      value={coll.name}
                      checked={coll.name in @selected_collections}
                      disabled={@ask_running}
                    />
                    <span><%= coll.name %></span>
                  </label>
                <% end %>
              </div>
              <small class="arcana-collection-hint">Select none for all collections</small>
            <% end %>
          </div>

          <%= if @ask_sub_tab == :pipeline do %>
            <div class="arcana-ask-options">
              <h4>
                Pipeline
                <span style="font-size: 0.75em; font-weight: normal; opacity: 0.6;">
                  <button
                    type="button"
                    class="arcana-pipeline-toggle-link"
                    phx-click="set_pipeline_steps"
                    phx-value-mode="all"
                  >all</button>
                  /
                  <button
                    type="button"
                    class="arcana-pipeline-toggle-link"
                    phx-click="set_pipeline_steps"
                    phx-value-mode="none"
                  >none</button>
                </span>
              </h4>
              <div class="arcana-pipeline-phases">
                <section class="arcana-pipeline-phase">
                  <header class="arcana-pipeline-phase-header">
                    <h5>Query preparation</h5>
                    <span class="arcana-pipeline-phase-toggle">
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="all" phx-value-group="query">all</button>
                      /
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="none" phx-value-group="query">none</button>
                    </span>
                  </header>
                  <ol class="arcana-pipeline">
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_gate" value="true" checked={@pipeline_steps["use_gate"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Gate</span>
                        <small>Skip retrieval if the LLM can answer from general knowledge</small>
                      </label>
                    </li>
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_rewrite" value="true" checked={@pipeline_steps["use_rewrite"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Query Rewriting</span>
                        <small>Clean up conversational input before search</small>
                      </label>
                    </li>
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_expand" value="true" checked={@pipeline_steps["use_expand"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Query Expansion</span>
                        <small>Generate related queries</small>
                      </label>
                    </li>
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_decompose" value="true" checked={@pipeline_steps["use_decompose"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Decomposition</span>
                        <small>Break into sub-questions</small>
                      </label>
                    </li>
                  </ol>
                </section>

                <section class="arcana-pipeline-phase">
                  <header class="arcana-pipeline-phase-header">
                    <h5>Retrieval</h5>
                    <span class="arcana-pipeline-phase-toggle">
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="all" phx-value-group="retrieval">all</button>
                      /
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="none" phx-value-group="retrieval">none</button>
                    </span>
                  </header>
                  <ol class="arcana-pipeline">
                    <li>
                      <%= if selected_graph_enabled?(@collections, @selected_collections) do %>
                        <div class="arcana-pipeline-fork">
                          <label class="arcana-pipeline-step">
                            <input type="radio" name="graph_search" value="false" disabled={@ask_running} />
                            <span class="arcana-step-label">Search</span>
                            <small>Retrieve relevant chunks</small>
                          </label>
                          <span class="arcana-fork-or">or</span>
                          <label class="arcana-pipeline-step">
                            <input type="radio" name="graph_search" value="true" checked disabled={@ask_running} />
                            <span class="arcana-step-label">Graph-Assisted Search</span>
                            <small>Find results through entity relationships</small>
                          </label>
                        </div>
                      <% else %>
                        <div class="arcana-pipeline-step fixed">
                          <span class="arcana-step-label">Search</span>
                          <small>Retrieve relevant chunks</small>
                        </div>
                      <% end %>
                    </li>
                    <li class="arcana-pipeline-substep">
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_reason" value="true" checked={@pipeline_steps["use_reason"]} disabled={@ask_running} />
                        <span class="arcana-step-label"><span class="arcana-loop-glyph">↻</span>Multi-hop Reasoning</span>
                        <small>Loops search with a follow-up query when chunks are thin</small>
                      </label>
                    </li>
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_rerank" value="true" checked={@pipeline_steps["use_rerank"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Reranking</span>
                        <small>Cross-encoder rescoring of retrieved chunks</small>
                      </label>
                    </li>
                  </ol>
                </section>

                <section class="arcana-pipeline-phase">
                  <header class="arcana-pipeline-phase-header">
                    <h5>Answer</h5>
                    <span class="arcana-pipeline-phase-toggle">
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="all" phx-value-group="answer">all</button>
                      /
                      <button type="button" class="arcana-pipeline-toggle-link"
                        phx-click="set_pipeline_steps" phx-value-mode="none" phx-value-group="answer">none</button>
                    </span>
                  </header>
                  <ol class="arcana-pipeline">
                    <li>
                      <div class="arcana-pipeline-fork">
                        <label class="arcana-pipeline-step">
                          <input type="radio" name="answer_mode" value="normal" checked disabled={@ask_running} />
                          <span class="arcana-step-label">Answer</span>
                          <small>Generate faithful answer</small>
                        </label>
                        <span class="arcana-fork-or">or</span>
                        <label class="arcana-pipeline-step">
                          <input type="radio" name="answer_mode" value="hallucinate" disabled={@ask_running} />
                          <span class="arcana-step-label">Answer with Hallucination</span>
                          <small>Mix in fake facts to showcase grounding</small>
                        </label>
                      </div>
                    </li>
                    <li class="arcana-pipeline-substep">
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="self_correct" value="true" checked={@pipeline_steps["self_correct"]} disabled={@ask_running} />
                        <span class="arcana-step-label"><span class="arcana-loop-glyph">↻</span>Self-Correction</span>
                        <small>Regenerate the answer if it isn't grounded in the chunks</small>
                      </label>
                    </li>
                    <li>
                      <label class="arcana-pipeline-step">
                        <input type="checkbox" name="use_ground" value="true" checked={@pipeline_steps["use_ground"]} disabled={@ask_running} />
                        <span class="arcana-step-label">Grounding</span>
                        <small>Detect hallucinated vs faithful spans</small>
                      </label>
                    </li>
                  </ol>
                </section>
              </div>
            </div>
          <% end %>

          <%= if @ask_sub_tab == :loop do %>
            <% llms = loop_llm_roles() %>
            <div class="arcana-loop-settings">
              <h4>Loop settings</h4>
              <div class="arcana-loop-settings-grid">
                <div class="arcana-loop-setting arcana-loop-setting--info">
                  <label>Controller LLM</label>
                  <small>Picks tools each turn.</small>
                  <div class="arcana-loop-setting-value"><%= llms.controller || "—" %></div>
                  <div class="arcana-loop-setting-temp">
                    <label for="controller_temperature">temp</label>
                    <input
                      type="number"
                      name="controller_temperature"
                      id="controller_temperature"
                      value="0.1"
                      min="0"
                      max="2"
                      step="0.1"
                      disabled={@ask_running}
                    />
                  </div>
                </div>
                <div class="arcana-loop-setting arcana-loop-setting--info">
                  <label>Answer LLM</label>
                  <small>
                    <%= if llms.answer,
                      do: "Rewrites the final user-facing answer.",
                      else: "Not set. Uses the controller's tool text directly." %>
                  </small>
                  <div class="arcana-loop-setting-value">
                    <%= llms.answer || "(uses controller)" %>
                  </div>
                  <%= if llms.answer do %>
                    <div class="arcana-loop-setting-temp">
                      <label for="answer_temperature">temp</label>
                      <input
                        type="number"
                        name="answer_temperature"
                        id="answer_temperature"
                        value="0.3"
                        min="0"
                        max="2"
                        step="0.1"
                        disabled={@ask_running}
                      />
                    </div>
                  <% end %>
                </div>
                <div class="arcana-loop-setting arcana-loop-setting--info">
                  <label>Fallback synthesizer</label>
                  <small>Used when max_iterations hits with chunks but no answer call.</small>
                  <div class="arcana-loop-setting-value"><%= llms.fallback || "—" %></div>
                  <div class="arcana-loop-setting-temp">
                    <label for="fallback_temperature">temp</label>
                    <input
                      type="number"
                      name="fallback_temperature"
                      id="fallback_temperature"
                      value="0.3"
                      min="0"
                      max="2"
                      step="0.1"
                      disabled={@ask_running}
                    />
                  </div>
                </div>
                <div class="arcana-loop-setting arcana-loop-setting--info">
                  <label>Tools (default set)</label>
                  <small>
                    <code>search</code> · <code>answer</code> · <code>give_up</code>
                  </small>
                </div>
                <div class="arcana-loop-setting arcana-loop-setting--number">
                  <label for="max_iterations">Max iterations</label>
                  <small>Hard cap on controller turns.</small>
                  <input
                    type="number"
                    name="max_iterations"
                    id="max_iterations"
                    value="10"
                    min="1"
                    max="50"
                    disabled={@ask_running}
                  />
                </div>
                <div class="arcana-loop-setting arcana-loop-setting--number">
                  <label for="chunk_cap">Chunk cap</label>
                  <small>Max chunks accumulated across iterations.</small>
                  <input
                    type="number"
                    name="chunk_cap"
                    id="chunk_cap"
                    value="50"
                    min="1"
                    max="200"
                    disabled={@ask_running}
                  />
                </div>
                <label class="arcana-loop-setting arcana-loop-setting--toggle">
                  <input
                    type="checkbox"
                    name="use_ground_loop"
                    value="true"
                    disabled={@ask_running}
                  />
                  <span class="arcana-loop-toggle-content">
                    <span class="arcana-loop-toggle-label">Run grounding after loop</span>
                    <small>LLM-as-judge faithfulness over accumulated chunks.</small>
                  </span>
                </label>
              </div>
            </div>
          <% end %>

          <div class="arcana-ask-actions">
            <button type="submit" disabled={@ask_running}>
              <%= if @ask_running, do: "Asking...", else: "Ask" %>
            </button>
            <%= if @ask_context do %>
              <button type="button" phx-click="ask_clear" disabled={@ask_running}>
                Clear
              </button>
            <% end %>
          </div>
        </form>

        <%= if @ask_running do %>
          <div class="arcana-ask-loading">
            <div class="arcana-spinner"></div>
            <span><%= ask_loading_label(@ask_sub_tab, @pipeline_step, @loop_phase) %></span>
          </div>

          <%= if @ask_sub_tab == :loop do %>
            <div class="arcana-loop-live-trace" id="loop-live-trace">
              <div class="arcana-loop-live-header">
                <span class="arcana-loop-live-pulse"></span>
                <span class="arcana-loop-live-title">Agent thinking</span>
                <span class="arcana-loop-live-count">
                  <%= length(@loop_live_history) %> <%= if length(@loop_live_history) == 1, do: "iteration", else: "iterations" %>
                </span>
              </div>

              <%= if @loop_live_history == [] do %>
                <div class="arcana-loop-live-empty">
                  Waiting for the controller's first move…
                </div>
              <% else %>
                <ol class="arcana-loop-iterations arcana-loop-iterations--live">
                  <%= for entry <- @loop_live_history do %>
                    <li class={"arcana-loop-iteration arcana-tool-#{entry.tool}"}>
                      <div class="arcana-loop-iter-header">
                        <span class="arcana-loop-iter-num">[<%= entry.iteration %>]</span>
                        <span class="arcana-loop-tool"><%= to_string(entry.tool) %></span>
                        <span class="arcana-loop-args">
                          <%= loop_arg_summary(entry.tool, entry.args) %>
                        </span>
                        <%= if length(entry.returned_chunk_ids) > 0 do %>
                          <span class="arcana-loop-chunk-count">
                            → <%= length(entry.returned_chunk_ids) %> chunks
                          </span>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </div>
          <% end %>

          <%= if @ask_sub_tab in [:pipeline, :advanced] do %>
            <div class="arcana-loop-live-trace" id="trace-live-trace">
              <div class="arcana-loop-live-header">
                <span class="arcana-loop-live-pulse"></span>
                <span class="arcana-loop-live-title">
                  <%= if @ask_sub_tab == :pipeline, do: "Pipeline", else: "Retrieval" %>
                </span>
                <span class="arcana-loop-live-count">
                  <%= length(@trace_history) %> <%= if length(@trace_history) == 1, do: "step", else: "steps" %>
                </span>
              </div>

              <%= if @trace_history == [] do %>
                <div class="arcana-loop-live-empty">
                  Waiting for the first step…
                </div>
              <% else %>
                <ol class="arcana-loop-iterations arcana-loop-iterations--live arcana-pipeline-iterations">
                  <%= for {entry, index} <- Enum.with_index(@trace_history, 1) do %>
                    <li class={"arcana-loop-iteration arcana-pipeline-step-trace arcana-pipeline-step-trace--#{entry.status}"}>
                      <div class="arcana-loop-iter-header">
                        <span class="arcana-loop-iter-num">
                          <%= if entry.status == :running do %>
                            <span class="arcana-pipeline-step-spinner"></span>
                          <% else %>
                            <%= index %>
                          <% end %>
                        </span>
                        <span class="arcana-loop-tool">
                          <%= pipeline_step_short(entry.step) %>
                        </span>
                        <span class="arcana-loop-args">
                          <%= pipeline_step_meta_summary(entry.step, entry.meta) %>
                        </span>
                        <%= if entry.status == :done and entry.duration_ms do %>
                          <span class="arcana-loop-chunk-count">
                            <%= format_duration(entry.duration_ms) %>
                          </span>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ol>
              <% end %>
            </div>
          <% end %>
        <% end %>

        <%= if @ask_context do %>
          <div class="arcana-ask-results">
            <div class="arcana-ask-answer">
              <h3>Answer</h3>
              <div class="arcana-answer-content">
                <%= cond do %>
                  <% is_nil(@ask_context.answer) -> %>
                    <span style="color: #9ca3af; font-style: italic;">No answer generated</span>
                  <% Map.get(@ask_context, :grounding) -> %>
                    <%= render_highlighted_answer(@ask_context.answer, @ask_context.grounding) %>
                  <% true -> %>
                    <%= render_markdown_answer(@ask_context.answer) %>
                <% end %>
              </div>
            </div>

            <%= if Map.get(@ask_context, :result_type) == :loop do %>
              <div class="arcana-ask-section arcana-loop-trace">
                <h4>
                  Agent trace
                  <span class="arcana-loop-meta">
                    <code><%= to_string(@ask_context.terminated_by) %></code>
                    &middot; <%= @ask_context.iterations %> iterations
                    &middot; <%= length(@ask_context.chunks) %> chunks accumulated
                  </span>
                </h4>

                <ol class="arcana-loop-iterations">
                  <%= for entry <- @ask_context.tool_history do %>
                    <li class={"arcana-loop-iteration arcana-tool-#{entry.tool}"}>
                      <div class="arcana-loop-iter-header">
                        <span class="arcana-loop-iter-num">[<%= entry.iteration %>]</span>
                        <span class="arcana-loop-tool"><%= to_string(entry.tool) %></span>
                        <span class="arcana-loop-args">
                          <%= loop_arg_summary(entry.tool, entry.args) %>
                        </span>
                        <%= if length(entry.returned_chunk_ids) > 0 do %>
                          <span class="arcana-loop-chunk-count">
                            → <%= length(entry.returned_chunk_ids) %> chunks
                          </span>
                        <% end %>
                      </div>
                    </li>
                  <% end %>
                </ol>
              </div>
            <% end %>

            <%= if Map.get(@ask_context, :grounding) do %>
              <div class="arcana-ask-section arcana-grounding-results">
                <h4>
                  Grounding
                  <span class={"arcana-grounding-score #{if @ask_context.grounding.score >= 0.8, do: "good", else: if(@ask_context.grounding.score >= 0.5, do: "warn", else: "bad")}"}>
                    <%= Float.round(@ask_context.grounding.score * 100, 1) %>% faithful
                  </span>
                </h4>

                <% chunks = Map.get(@ask_context, :results, []) %>

                <%= if length(@ask_context.grounding.hallucinated_spans) > 0 do %>
                  <div class="arcana-grounding-spans">
                    <h5>Hallucinated Spans</h5>
                    <%= for span <- @ask_context.grounding.hallucinated_spans do %>
                      <div class="arcana-span hallucinated">
                        <span class="arcana-span-text"><%= span.text %></span>
                        <span class="arcana-span-score"><%= Float.round(span.score, 2) %></span>
                        <.source_previews sources={Map.get(span, :sources, [])} chunks={chunks} />
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if length(@ask_context.grounding.faithful_spans) > 0 do %>
                  <div class="arcana-grounding-spans">
                    <h5>Faithful Spans (<%= length(@ask_context.grounding.faithful_spans) %>)</h5>
                    <%= for span <- @ask_context.grounding.faithful_spans do %>
                      <div class="arcana-span faithful">
                        <span class="arcana-span-text"><%= span.text %></span>
                        <.source_previews sources={Map.get(span, :sources, [])} chunks={chunks} />
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if pipeline_internals?(@ask_context) do %>
              <div class="arcana-ask-section arcana-pipeline-internals">
                <h4>Pipeline internals</h4>
                <dl class="arcana-pipeline-internals-list">
                  <%= if rq = Map.get(@ask_context, :rewritten_query) do %>
                    <dt>Rewritten query</dt>
                    <dd class="arcana-pipeline-internals-quote">"<%= rq %>"</dd>
                  <% end %>

                  <%= case Map.get(@ask_context, :skip_retrieval) do %>
                    <% nil -> %>
                    <% skip -> %>
                      <dt>Gate decision</dt>
                      <dd>
                        <span class={"arcana-pipeline-internals-badge #{if skip, do: "skip", else: "retrieve"}"}>
                          <%= if skip, do: "skip retrieval", else: "retrieve" %>
                        </span>
                        <%= if reasoning = Map.get(@ask_context, :gate_reasoning) do %>
                          <span class="arcana-pipeline-internals-reasoning"><%= reasoning %></span>
                        <% end %>
                      </dd>
                  <% end %>

                  <%= if eq = Map.get(@ask_context, :expanded_query) do %>
                    <dt>Expanded query</dt>
                    <dd class="arcana-pipeline-internals-quote">"<%= eq %>"</dd>
                  <% end %>

                  <% sub_qs = Map.get(@ask_context, :sub_questions) %>
                  <%= if sub_qs && length(sub_qs) > 0 do %>
                    <dt>Sub-questions (<%= length(sub_qs) %>)</dt>
                    <dd>
                      <ul class="arcana-query-list">
                        <%= for sq <- sub_qs do %>
                          <li><%= sq %></li>
                        <% end %>
                      </ul>
                    </dd>
                  <% end %>

                  <%= case Map.get(@ask_context, :reason_iterations) do %>
                    <% nil -> %>
                    <% 0 -> %>
                      <dt>Multi-hop reasoning</dt>
                      <dd>
                        <span class="arcana-pipeline-internals-badge neutral">chunks sufficient, no follow-up</span>
                      </dd>
                    <% n -> %>
                      <dt>Multi-hop reasoning (<%= n %> follow-ups)</dt>
                      <dd>
                        <% tried = Map.get(@ask_context, :queries_tried) || MapSet.new() %>
                        <ul class="arcana-query-list">
                          <%= for q <- MapSet.to_list(tried) do %>
                            <li>"<%= q %>"</li>
                          <% end %>
                        </ul>
                      </dd>
                  <% end %>

                  <% graph_count = Map.get(@ask_context, :graph_sourced_count) || 0 %>
                  <% retrieved = Map.get(@ask_context, :retrieved_count) || 0 %>
                  <%= if graph_count > 0 do %>
                    <dt>Graph-assisted retrieval</dt>
                    <dd>
                      <span class="arcana-pipeline-internals-badge neutral">
                        <%= graph_count %>/<%= retrieved %> chunks found via entity relationships
                      </span>
                    </dd>
                  <% end %>

                  <% rerank_kept = Map.get(@ask_context, :rerank_kept) || 0 %>
                  <%= if rerank_kept > 0 do %>
                    <dt>Reranking</dt>
                    <dd>
                      <% scores = Map.get(@ask_context, :rerank_scores) || %{} %>
                      <% sorted = scores |> Map.values() |> Enum.sort(:desc) %>
                      <% top = List.first(sorted) %>
                      <% bottom = List.last(sorted) %>
                      <span class="arcana-pipeline-internals-badge neutral">
                        <%= rerank_kept %> chunks reordered
                        <%= if top && bottom && rerank_kept > 1 do %>
                          (top score <%= :erlang.float_to_binary(top * 1.0, decimals: 2) %>, bottom <%= :erlang.float_to_binary(bottom * 1.0, decimals: 2) %>)
                        <% end %>
                      </span>
                    </dd>
                  <% end %>

                  <%= case Map.get(@ask_context, :correction_count) do %>
                    <% nil -> %>
                    <% 0 -> %>
                    <% n -> %>
                      <dt>Self-correction (<%= n %> <%= if n == 1, do: "retry", else: "retries" %>)</dt>
                      <dd>
                        <% corrs = Map.get(@ask_context, :corrections) || [] %>
                        <%= for {_prev, feedback} <- corrs do %>
                          <div class="arcana-pipeline-internals-feedback"><%= feedback %></div>
                        <% end %>
                      </dd>
                  <% end %>
                </dl>
              </div>
            <% end %>

            <% sel_cols = Map.get(@ask_context, :selected_collections) %>
            <%= if sel_cols && length(sel_cols) > 0 do %>
              <div class="arcana-ask-section">
                <h4>Selected Collections</h4>
                <div class="arcana-collection-badges">
                  <%= for coll <- sel_cols do %>
                    <span class="arcana-collection-badge"><%= coll %></span>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%= if Map.get(@ask_context, :graph_enhanced) do %>
              <.graph_context_section
                matched_entities={Map.get(@ask_context, :matched_entities, [])}
                matched_relationships={Map.get(@ask_context, :matched_relationships, [])}
                expanded={@graph_context_expanded}
              />
            <% end %>

            <% all_results = Map.get(@ask_context, :results) %>
            <%= if all_results && length(all_results) > 0 do %>
              <div class="arcana-ask-section">
                <h4>Retrieved Chunks (<%= length(all_results) %>)</h4>
                <ChunkResultsComponent.chunk_results
                  chunks={all_results}
                  document_titles={Map.get(@ask_context, :document_titles, %{})}
                  grounding={Map.get(@ask_context, :grounding)}
                  id="ask-chunk-results"
                />
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp graph_context_section(assigns) do
    ~H"""
    <div class="arcana-graph-context">
      <div class="arcana-graph-context-header">
        <h4>Graph Context</h4>
        <button type="button" phx-click="toggle_graph_context" class="arcana-toggle-btn">
          <%= if @expanded, do: "▼", else: "▶" %>
        </button>
      </div>

      <%= if @expanded do %>
        <div class="arcana-graph-context-content">
          <%= if length(@matched_entities) == 0 and length(@matched_relationships) == 0 do %>
            <p class="arcana-no-matches">No entity matches — used vector search only</p>
          <% else %>
            <%= if length(@matched_entities) > 0 do %>
              <div class="arcana-matched-entities">
                <h5>Matched Entities</h5>
                <ul>
                  <%= for entity <- @matched_entities do %>
                    <li>
                      <span class="arcana-entity-name"><%= entity.name %></span>
                      <span class="arcana-entity-type"><%= entity.type %></span>
                      <%= if Map.get(entity, :id) do %>
                        <a href={"/arcana/graph?entity=#{entity.id}"} class="arcana-view-in-graph">
                          View in Graph
                        </a>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <%= if length(@matched_relationships) > 0 do %>
              <div class="arcana-matched-relationships">
                <h5>Key Relationships</h5>
                <ul>
                  <%= for rel <- @matched_relationships do %>
                    <li>
                      <span class="arcana-rel-source"><%= rel.source %></span>
                      <span class="arcana-rel-type">—<%= rel.type %>→</span>
                      <span class="arcana-rel-target"><%= rel.target %></span>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp source_previews(assigns) do
    ~H"""
    <%= if @sources != [] do %>
      <div class="arcana-span-sources">
        <%= for source <- @sources do %>
          <% chunk = find_chunk(@chunks, source.chunk_id) %>
          <details class="arcana-source-detail">
            <summary class="arcana-source-badge clickable">
              <span class="arcana-source-label">
                <%= chunk_label(chunk) %>
              </span>
              <span class="arcana-source-overlap"><%= Float.round(source.score * 100) %>% overlap</span>
            </summary>
            <%= if chunk do %>
              <div class="arcana-source-preview"><%= chunk.text %></div>
            <% end %>
          </details>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp find_chunk(chunks, chunk_id) do
    Enum.find(chunks, fn chunk ->
      id = if is_struct(chunk), do: chunk.id, else: Map.get(chunk, :id)
      to_string(id) == to_string(chunk_id)
    end)
  end

  defp chunk_label(nil), do: "unknown chunk"

  defp chunk_label(chunk) do
    index = Map.get(chunk, :chunk_index, nil)
    if index, do: "Chunk #{index}", else: "Source"
  end

  defp render_highlighted_answer(answer, grounding) do
    hallucinated = Map.get(grounding, :hallucinated_spans, [])
    faithful = Map.get(grounding, :faithful_spans, [])

    spans =
      (Enum.map(hallucinated, &Map.put(&1, :type, :hallucinated)) ++
         Enum.map(faithful, &Map.put(&1, :type, :faithful)))
      |> Enum.sort_by(& &1.start)

    build_highlighted_parts(answer, spans, 0, [])
    |> Enum.reverse()
    |> Phoenix.HTML.raw()
  end

  defp build_highlighted_parts(answer, [], pos, acc) do
    rest = binary_slice(answer, pos, byte_size(answer) - pos)
    if rest == "", do: acc, else: [html_escape(rest) | acc]
  end

  defp build_highlighted_parts(answer, [span | rest], pos, acc) do
    span_start = span.start
    span_end = Map.get(span, :end, span_start)

    # Text before this span
    acc =
      if span_start > pos do
        gap = binary_slice(answer, pos, span_start - pos)
        [html_escape(gap) | acc]
      else
        acc
      end

    # The span itself
    span_text = binary_slice(answer, span_start, span_end - span_start)

    class =
      if span.type == :hallucinated, do: "arcana-hl-hallucinated", else: "arcana-hl-faithful"

    acc = [
      ~s(<mark class="#{class}" title="#{span.type}">#{html_escape(span_text)}</mark>) | acc
    ]

    build_highlighted_parts(answer, rest, span_end, acc)
  end

  defp html_escape(text) do
    text
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  # tool_history entries go through Loop.atomize_keys/1 before they're
  # recorded, so args always have atom keys by the time they reach here.
  # The fallback clause handles custom tools with unknown arg shapes.
  defp loop_arg_summary(:search, %{query: q}) when is_binary(q), do: ~s("#{q}")
  defp loop_arg_summary(:answer, %{text: t}) when is_binary(t), do: truncate_arg(t)
  defp loop_arg_summary(:synthesis, %{text: t}) when is_binary(t), do: truncate_arg(t)
  defp loop_arg_summary(:give_up, %{reason: r}) when is_binary(r), do: truncate_arg(r)
  defp loop_arg_summary(_, _), do: ""

  defp truncate_arg(s) when byte_size(s) <= 80, do: ~s("#{s}")

  defp truncate_arg(s) do
    head = binary_part(s, 0, 77)
    ~s("#{head}...")
  end

  defp pipeline_step_label(:gate), do: "Deciding if retrieval is needed..."
  defp pipeline_step_label(:rewrite), do: "Rewriting query..."
  defp pipeline_step_label(:expand), do: "Expanding query..."
  defp pipeline_step_label(:decompose), do: "Decomposing question..."
  defp pipeline_step_label(:select), do: "Selecting collections..."
  defp pipeline_step_label(:search), do: "Searching..."
  defp pipeline_step_label(:reason), do: "Multi-hop reasoning..."
  defp pipeline_step_label(:self_correct), do: "Refining search..."
  defp pipeline_step_label(:rerank), do: "Reranking results..."
  defp pipeline_step_label(:answer), do: "Generating answer..."
  defp pipeline_step_label(:ground), do: "Checking for hallucinations..."
  defp pipeline_step_label(_), do: nil

  # True when at least one pipeline step wrote an inspectable output to
  # the ask_context. Keeps the "Pipeline internals" section from showing
  # an empty shell on Advanced runs that don't touch these fields.
  defp pipeline_internals?(%{} = ctx) do
    not is_nil(Map.get(ctx, :rewritten_query)) or
      not is_nil(Map.get(ctx, :expanded_query)) or
      not is_nil(Map.get(ctx, :skip_retrieval)) or
      not is_nil(Map.get(ctx, :reason_iterations)) or
      (Map.get(ctx, :correction_count) || 0) > 0 or
      (Map.get(ctx, :rerank_kept) || 0) > 0 or
      (Map.get(ctx, :graph_sourced_count) || 0) > 0 or
      match?([_ | _], Map.get(ctx, :sub_questions))
  end

  defp pipeline_internals?(_), do: false

  # Short labels for the trace tool badge. Covers both Pipeline step
  # names and the top-level events that fire during an Advanced run
  # (Arcana.search/2 → graph search → LLM answer generation).
  defp pipeline_step_short(:gate), do: "gate"
  defp pipeline_step_short(:rewrite), do: "rewrite"
  defp pipeline_step_short(:expand), do: "expand"
  defp pipeline_step_short(:decompose), do: "decompose"
  defp pipeline_step_short(:select), do: "select"
  defp pipeline_step_short(:search), do: "search"
  defp pipeline_step_short(:reason), do: "reason"
  defp pipeline_step_short(:self_correct), do: "self_correct"
  defp pipeline_step_short(:rerank), do: "rerank"
  defp pipeline_step_short(:answer), do: "answer"
  defp pipeline_step_short(:ground), do: "ground"
  defp pipeline_step_short(:graph_search), do: "graph_search"
  defp pipeline_step_short(:llm_complete), do: "llm"
  defp pipeline_step_short(other), do: to_string(other)

  # Picks the most useful one-liner from a pipeline step's :stop
  # telemetry metadata. Each step emits different keys, so we look
  # for the ones the pipeline actually populates and fall back to "".
  defp pipeline_step_meta_summary(_step, nil), do: ""

  defp pipeline_step_meta_summary(:rewrite, %{rewritten_query: q}) when is_binary(q),
    do: ~s("#{q}")

  defp pipeline_step_meta_summary(:expand, %{expanded_query: q}) when is_binary(q),
    do: ~s("#{q}")

  defp pipeline_step_meta_summary(:decompose, %{sub_questions: subs}) when is_list(subs),
    do: "#{length(subs)} sub-questions"

  defp pipeline_step_meta_summary(:select, %{collections: colls}) when is_list(colls),
    do: Enum.join(colls, ", ")

  defp pipeline_step_meta_summary(:search, %{result_count: n}), do: "#{n} chunks"

  defp pipeline_step_meta_summary(:search, %{results: r}) when is_list(r),
    do: "#{length(r)} chunks"

  defp pipeline_step_meta_summary(:rerank, %{result_count: n}), do: "#{n} kept"
  defp pipeline_step_meta_summary(:gate, %{skip_retrieval: true}), do: "skip retrieval"
  defp pipeline_step_meta_summary(:gate, %{skip_retrieval: false}), do: "retrieve"

  defp pipeline_step_meta_summary(:graph_search, %{entity_count: n, result_count: r}),
    do: "#{n} entities → #{r} chunks"

  defp pipeline_step_meta_summary(:graph_search, %{entity_count: n}),
    do: "#{n} entities"

  defp pipeline_step_meta_summary(:llm_complete, %{model: model}) when is_binary(model),
    do: model

  defp pipeline_step_meta_summary(:llm_complete, _), do: ""
  defp pipeline_step_meta_summary(_step, _meta), do: ""

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
