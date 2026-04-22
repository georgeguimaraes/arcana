defmodule ArcanaWeb.EvaluationLive do
  @moduledoc """
  LiveView for retrieval evaluation in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  alias Arcana.Evaluation

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       eval_view: :test_cases,
       eval_running: false,
       eval_generating: false,
       eval_progress: nil,
       eval_tick: 0,
       eval_message: nil,
       expanded_test_case_id: nil,
       stats: nil,
       eval_test_cases: [],
       eval_runs: [],
       eval_test_case_count: 0,
       collections: []
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> load_evaluation_data()
  end

  defp load_evaluation_data(socket) do
    repo = socket.assigns.repo

    test_cases = Evaluation.list_test_cases(repo: repo)
    runs = Evaluation.list_runs(repo: repo, limit: 10)
    test_case_count = Evaluation.count_test_cases(repo: repo)
    collections = load_collections(repo)

    assign(socket,
      eval_test_cases: test_cases,
      eval_runs: runs,
      eval_test_case_count: test_case_count,
      collections: collections
    )
  end

  @impl true
  def handle_event("eval_switch_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, eval_view: parse_eval_view(view))}
  end

  def handle_event("eval_run", params, socket) do
    repo = socket.assigns.repo
    mode = parse_mode(params["mode"])
    retriever_name = params["retriever"] || "pipeline"
    evaluate_answers = params["evaluate_answers"] == "true"

    # Check if LLM is configured when evaluate_answers or Loop is requested
    llm = Application.get_env(:arcana, :llm)
    needs_llm? = evaluate_answers or retriever_name == "loop"

    if needs_llm? and is_nil(llm) do
      {:noreply,
       assign(socket,
         eval_message: {:error, "No LLM configured. Set :arcana, :llm in your config."}
       )}
    else
      socket =
        assign(socket,
          eval_running: true,
          eval_message: nil,
          eval_progress: %{
            done: 0,
            total: socket.assigns.eval_test_case_count,
            started_at: System.monotonic_time(:millisecond)
          }
        )

      opts = build_run_opts(repo, mode, evaluate_answers, llm, retriever_name)

      parent = self()
      handler_id = "eval-progress-#{inspect(parent)}"

      :telemetry.attach_many(
        handler_id,
        [
          [:arcana, :evaluation, :test_case, :start],
          [:arcana, :evaluation, :test_case, :complete]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:eval_progress, event, measurements, metadata})
        end,
        nil
      )

      Task.Supervisor.start_child(Arcana.TaskSupervisor, fn ->
        result = Evaluation.run(opts)
        :telemetry.detach(handler_id)
        send(parent, {:eval_run_complete, result})
      end)

      # Self-tick every second so the elapsed-time counter updates live
      # while a test case is in flight. LiveView only re-renders on
      # messages; without a tick the elapsed-time label freezes at
      # whatever it was when the last telemetry event fired.
      Process.send_after(self(), :eval_tick, 1000)

      {:noreply, socket}
    end
  end

  def handle_event("eval_generate", params, socket) do
    repo = socket.assigns.repo
    sample_size = parse_int(params["sample_size"], 10)
    collection = blank_to_nil(params["collection"])

    case Application.get_env(:arcana, :llm) do
      nil ->
        {:noreply,
         assign(socket,
           eval_message: {:error, "No LLM configured. Set :arcana, :llm in your config."}
         )}

      llm ->
        socket = assign(socket, eval_generating: true, eval_message: nil)

        parent = self()
        opts = build_generate_opts(repo, llm, sample_size, collection)

        Task.Supervisor.start_child(Arcana.TaskSupervisor, fn ->
          result = Evaluation.generate_test_cases(opts)
          send(parent, {:eval_generate_complete, result})
        end)

        {:noreply, socket}
    end
  end

  def handle_event("toggle_test_case", %{"id" => id}, socket) do
    current = socket.assigns.expanded_test_case_id
    next = if current == id, do: nil, else: id
    {:noreply, assign(socket, expanded_test_case_id: next)}
  end

  def handle_event("eval_delete_test_case", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case Evaluation.delete_test_case(id, repo: repo) do
      {:ok, _} -> {:noreply, load_evaluation_data(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_event("eval_delete_run", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case Evaluation.delete_run(id, repo: repo) do
      {:ok, _} -> {:noreply, load_evaluation_data(socket)}
      {:error, _} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:eval_tick, socket) do
    # Keep ticking while the eval task is running. No assign change
    # beyond the implicit re-render; the template reads the monotonic
    # clock each render so the elapsed display refreshes on its own.
    if socket.assigns.eval_running do
      Process.send_after(self(), :eval_tick, 1000)
      {:noreply, assign(socket, eval_tick: System.monotonic_time(:millisecond))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:eval_progress, event, _measurements, metadata}, socket) do
    %{index: index, total: total, question: question} = metadata

    base =
      socket.assigns.eval_progress ||
        %{done: 0, total: total, started_at: System.monotonic_time(:millisecond), current: nil}

    progress =
      case List.last(event) do
        :start ->
          # New test case just kicked off; surface it as "now running"
          # so the user sees motion even while a slow Loop iteration is
          # in flight (can take several minutes per case).
          %{base | total: total, current: %{index: index, question: question}}

        :complete ->
          # Test case finished; bump the done count and clear current
          # so the bar reflects the new done-out-of-total.
          %{base | done: index, total: total, current: nil}
      end

    {:noreply, assign(socket, eval_progress: progress)}
  end

  def handle_info({:eval_run_complete, result}, socket) do
    socket =
      case result do
        {:ok, _run} ->
          socket
          |> assign(
            eval_running: false,
            eval_progress: nil,
            eval_message: {:success, "Evaluation completed!"}
          )
          |> load_evaluation_data()
          |> assign(eval_view: :history)

        {:error, :no_test_cases} ->
          assign(socket,
            eval_running: false,
            eval_progress: nil,
            eval_message: {:error, "No test cases. Generate some first."}
          )

        other ->
          # Fallback: the eval task raised or returned an unexpected
          # result. Clear the running flag so the UI doesn't get stuck
          # on "Running..." forever.
          require Logger
          Logger.error("[EvaluationLive] unexpected eval result: #{inspect(other)}")

          assign(socket,
            eval_running: false,
            eval_progress: nil,
            eval_message: {:error, "Evaluation failed: #{inspect(other)}"}
          )
      end

    {:noreply, socket}
  end

  def handle_info({:eval_generate_complete, result}, socket) do
    socket =
      case result do
        {:ok, test_cases} ->
          socket
          |> assign(
            eval_generating: false,
            eval_message: {:success, "Generated #{length(test_cases)} test case(s)!"}
          )
          |> load_evaluation_data()

        {:error, reason} ->
          assign(socket,
            eval_generating: false,
            eval_message: {:error, "Generation failed: #{inspect(reason)}"}
          )
      end

    {:noreply, socket}
  end

  defp build_run_opts(repo, mode, evaluate_answers, llm, retriever_name) do
    base =
      [repo: repo, mode: mode]
      |> maybe_put_evaluate_answers(evaluate_answers, llm)
      |> maybe_put_retriever(retriever_name, repo, llm)

    base
  end

  defp maybe_put_evaluate_answers(opts, false, _llm), do: opts

  defp maybe_put_evaluate_answers(opts, true, llm) do
    Keyword.merge(opts, evaluate_answers: true, llm: llm)
  end

  # Pipeline is the default — no :retriever needed, Arcana.Evaluation.run/1
  # falls back to &Arcana.search/2.
  defp maybe_put_retriever(opts, "pipeline", _repo, _llm), do: opts

  defp maybe_put_retriever(opts, "loop", repo, llm) do
    # Loop retriever: run a full Arcana.Loop.run/2 per test case and
    # return the 3-tuple {:ok, chunks, answer}. The answer is the one
    # the loop produced, so when evaluate_answers: true is on, the
    # existing machinery skips regeneration and scores it directly.
    runner = loop_runner()

    retriever = fn question, _opts ->
      ctx = Arcana.Loop.new(question, repo: repo)

      case runner.(ctx, controller_llm: llm) do
        {:ok, %Arcana.Loop.Context{} = result_ctx} ->
          {:ok, result_ctx.chunks, result_ctx.answer}

        {:error, _} = err ->
          err
      end
    end

    Keyword.put(opts, :retriever, retriever)
  end

  # Testability seam — same pattern used in ask_live.ex so tests can
  # stub Loop execution without spinning up a real controller.
  defp loop_runner do
    Application.get_env(:arcana, :loop_runner) || (&Arcana.Loop.run/2)
  end

  defp build_generate_opts(repo, llm, sample_size, nil) do
    [repo: repo, llm: llm, sample_size: sample_size]
  end

  defp build_generate_opts(repo, llm, sample_size, collection) do
    [repo: repo, llm: llm, sample_size: sample_size, collection: collection]
  end

  defp parse_eval_view("test_cases"), do: :test_cases
  defp parse_eval_view("run"), do: :run
  defp parse_eval_view("history"), do: :history
  # Any other value (an unknown view name from a stale tab or a malformed
  # phx-value-view payload) falls back to the default landing.
  defp parse_eval_view(_), do: :test_cases

  defp progress_pct(%{done: done, total: total}) when total > 0,
    do: Float.round(done / total * 100, 1)

  defp progress_pct(_), do: 0.0

  defp format_elapsed(ms) when ms < 1000, do: "#{ms}ms"

  defp format_elapsed(ms) when ms < 60_000,
    do: "#{Float.round(ms / 1000, 1)}s"

  defp format_elapsed(ms) do
    total_s = div(ms, 1000)
    "#{div(total_s, 60)}m #{rem(total_s, 60)}s"
  end

  # Humanized "2 hours ago"-style relative time for timestamps in lists.
  # Falls back to the absolute string for anything older than a week so
  # months/years don't get ambiguous.
  defp relative_time(nil), do: ""

  defp relative_time(%NaiveDateTime{} = dt) do
    now = NaiveDateTime.utc_now()
    diff_s = NaiveDateTime.diff(now, dt, :second)

    cond do
      diff_s < 0 -> "just now"
      diff_s < 60 -> "just now"
      diff_s < 3600 -> "#{div(diff_s, 60)}m ago"
      diff_s < 86_400 -> "#{div(diff_s, 3600)}h ago"
      diff_s < 604_800 -> "#{div(diff_s, 86_400)}d ago"
      true -> NaiveDateTime.to_date(dt) |> Date.to_string()
    end
  end

  defp relative_time(other), do: to_string(other)

  defp absolute_time(%NaiveDateTime{} = dt),
    do: NaiveDateTime.to_string(dt)

  defp absolute_time(other), do: to_string(other)

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:evaluation}>
      <div class="arcana-evaluation">
        <h2>Evaluation</h2>
        <p class="arcana-tab-description">
          Test retrieval quality with test cases and measure recall and precision metrics.
        </p>

        <div class="arcana-eval-nav">
          <button
            class={"arcana-eval-nav-btn #{if @eval_view == :test_cases, do: "active", else: ""}"}
            phx-click="eval_switch_view"
            phx-value-view="test_cases"
          >
            Test Cases (<%= @eval_test_case_count %>)
          </button>
          <button
            class={"arcana-eval-nav-btn #{if @eval_view == :run, do: "active", else: ""}"}
            phx-click="eval_switch_view"
            phx-value-view="run"
          >
            Run Evaluation
          </button>
          <button
            class={"arcana-eval-nav-btn #{if @eval_view == :history, do: "active", else: ""}"}
            phx-click="eval_switch_view"
            phx-value-view="history"
          >
            History (<%= length(@eval_runs) %>)
          </button>
        </div>

        <%= if @eval_message do %>
          <div class={"arcana-eval-message #{elem(@eval_message, 0)}"}>
            <%= elem(@eval_message, 1) %>
          </div>
        <% end %>

        <%= case @eval_view do %>
          <% :test_cases -> %>
            <.eval_test_cases_view
              test_cases={@eval_test_cases}
              generating={@eval_generating}
              collections={@collections}
              expanded_id={@expanded_test_case_id}
            />
          <% :run -> %>
            <.eval_run_view
              running={@eval_running}
              progress={@eval_progress}
              test_case_count={@eval_test_case_count}
            />
          <% :history -> %>
            <.eval_history_view runs={@eval_runs} />
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp eval_test_cases_view(assigns) do
    ~H"""
    <div class="arcana-eval-test-cases">
      <form phx-submit="eval_generate" class="arcana-eval-run-form">
        <div class="arcana-eval-options-row">
          <div class="arcana-eval-field">
            <label class="arcana-eval-field-label" for="eval-collection">Collection</label>
            <select name="collection" id="eval-collection" class="arcana-eval-select">
              <option value="">All collections</option>
              <%= for col <- @collections do %>
                <option value={col.name}><%= col.name %></option>
              <% end %>
            </select>
            <small class="arcana-eval-hint">Leave blank to sample from every collection.</small>
          </div>

          <div class="arcana-eval-field">
            <label class="arcana-eval-field-label" for="eval-sample-size">Sample size</label>
            <select name="sample_size" id="eval-sample-size" class="arcana-eval-select">
              <option value="5">5</option>
              <option value="10" selected>10</option>
              <option value="25">25</option>
              <option value="50">50</option>
              <option value="100">100</option>
            </select>
            <small class="arcana-eval-hint">
              Random chunks sampled and paired with LLM-generated questions.
            </small>
          </div>
        </div>

        <div class="arcana-eval-actions">
          <button type="submit" class="arcana-eval-run-btn" disabled={@generating}>
            <%= if @generating, do: "Generating...", else: "Generate test cases" %>
          </button>
        </div>
      </form>

      <%= if Enum.empty?(@test_cases) do %>
        <div class="arcana-eval-empty-state">
          <div class="arcana-eval-empty-icon">○</div>
          <h4>No test cases yet</h4>
          <p>
            Generate some with the form above, or seed from Mix with
            <code>mix adept.eval.seed</code>.
          </p>
        </div>
      <% else %>
        <div class="arcana-test-case-list">
          <%= for tc <- @test_cases do %>
            <% expanded? = @expanded_id == tc.id %>
            <div class={"arcana-test-case #{if expanded?, do: "expanded", else: ""}"}>
              <div class="arcana-test-case-row">
                <div
                  class="arcana-test-case-row-main"
                  phx-click="toggle_test_case"
                  phx-value-id={tc.id}
                >
                  <span class="arcana-test-case-chevron" aria-hidden="true">
                    <%= if expanded?, do: "▾", else: "▸" %>
                  </span>
                  <span class="arcana-test-case-question"><%= tc.question %></span>
                  <span class={"arcana-test-case-badge arcana-test-case-badge--#{tc.source}"}>
                    <%= tc.source %>
                  </span>
                  <span class="arcana-test-case-chunks">
                    <%= length(tc.relevant_chunks) %> chunk<%= if length(tc.relevant_chunks) == 1, do: "", else: "s" %>
                  </span>
                  <span class="arcana-test-case-time" title={absolute_time(tc.inserted_at)}>
                    <%= relative_time(tc.inserted_at) %>
                  </span>
                </div>
                <button
                  type="button"
                  class="arcana-delete-btn"
                  phx-click="eval_delete_test_case"
                  phx-value-id={tc.id}
                  title="Delete test case"
                >
                  ×
                </button>
              </div>
              <%= if expanded? do %>
                <div class="arcana-test-case-detail">
                  <%= if tc.reference_answer do %>
                    <div class="arcana-test-case-detail-section">
                      <h5>Reference answer</h5>
                      <p><%= tc.reference_answer %></p>
                    </div>
                  <% end %>
                  <div class="arcana-test-case-detail-section">
                    <h5>Expected chunks (<%= length(tc.relevant_chunks) %>)</h5>
                    <%= if Enum.empty?(tc.relevant_chunks) do %>
                      <p class="arcana-test-case-empty">No chunks linked.</p>
                    <% else %>
                      <ul class="arcana-test-case-chunk-list">
                        <%= for chunk <- tc.relevant_chunks do %>
                          <li>
                            <code class="arcana-test-case-chunk-id">
                              <%= String.slice(to_string(chunk.id), 0, 8) %>
                            </code>
                            <span class="arcana-test-case-chunk-text">
                              <%= String.slice(chunk.text || "", 0, 200) %><%= if String.length(chunk.text || "") > 200, do: "..." %>
                            </span>
                          </li>
                        <% end %>
                      </ul>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp eval_run_view(assigns) do
    ~H"""
    <div class="arcana-eval-run">
      <p class="arcana-eval-run-intro">
        Run evaluation against your <strong><%= @test_case_count %></strong> test case{if @test_case_count == 1, do: "", else: "s"} to measure retrieval quality.
      </p>

      <form phx-submit="eval_run" class="arcana-eval-run-form">
        <div class="arcana-eval-field">
          <h4 class="arcana-eval-field-label">Retriever</h4>
          <div class="arcana-eval-option-grid">
            <label class="arcana-eval-option-card">
              <input type="radio" name="retriever" value="pipeline" checked />
              <div class="arcana-eval-option-title">Pipeline</div>
              <div class="arcana-eval-option-desc">
                Modular RAG via <code>Arcana.search/2</code>. Fast, deterministic.
              </div>
            </label>
            <label class="arcana-eval-option-card">
              <input type="radio" name="retriever" value="loop" />
              <div class="arcana-eval-option-title">Loop</div>
              <div class="arcana-eval-option-desc">
                Agentic RAG via <code>Arcana.Loop</code>. LLM picks tools each turn. Much slower, needs LLM.
              </div>
            </label>
          </div>
        </div>

        <div class="arcana-eval-options-row">
          <div class="arcana-eval-field">
            <label class="arcana-eval-field-label" for="eval-mode">Search mode</label>
            <select name="mode" id="eval-mode" class="arcana-eval-select">
              <option value="vector">Vector</option>
              <option value="keyword">Keyword</option>
              <option value="hybrid">Hybrid</option>
            </select>
            <small class="arcana-eval-hint">
              Vector: embedding similarity. Keyword: exact terms. Hybrid: both fused by RRF.
              Pipeline only; Loop always uses vector.
            </small>
          </div>

          <label class="arcana-eval-toggle">
            <input type="checkbox" name="evaluate_answers" value="true" />
            <span class="arcana-eval-toggle-indicator" aria-hidden="true"></span>
            <div class="arcana-eval-toggle-content">
              <span class="arcana-eval-toggle-title">Evaluate answers</span>
              <small class="arcana-eval-hint">
                Requires LLM. Scores faithfulness and correctness against reference_answer.
              </small>
            </div>
          </label>
        </div>

        <div class="arcana-eval-actions">
          <%= if @running and @progress do %>
            <div class="arcana-eval-progress">
              <div class="arcana-eval-progress-label">
                <span><%= @progress.done %> / <%= @progress.total %> test cases</span>
                <span class="arcana-eval-progress-elapsed">
                  <%= format_elapsed(System.monotonic_time(:millisecond) - @progress.started_at) %>
                </span>
              </div>
              <div class="arcana-eval-progress-bar">
                <div
                  class="arcana-eval-progress-fill"
                  style={"width: #{progress_pct(@progress)}%"}
                ></div>
              </div>
              <%= if current = @progress[:current] do %>
                <div class="arcana-eval-progress-current">
                  <span class="arcana-eval-progress-spinner" aria-hidden="true"></span>
                  <span class="arcana-eval-progress-current-label">
                    Running case <%= current.index %>: <%= current.question %>
                  </span>
                </div>
              <% end %>
            </div>
          <% end %>
          <button type="submit" class="arcana-eval-run-btn" disabled={@running or @test_case_count == 0}>
            <%= if @running, do: "Running...", else: "Run Evaluation" %>
          </button>
        </div>
      </form>

      <%= if @test_case_count == 0 do %>
        <p class="arcana-empty">
          No test cases available. Generate some first using <code>mix arcana.eval.generate</code>.
        </p>
      <% end %>
    </div>
    """
  end

  defp eval_history_view(assigns) do
    ~H"""
    <div class="arcana-eval-history">
      <%= if Enum.empty?(@runs) do %>
        <p class="arcana-empty">No evaluation runs yet. Run an evaluation to see results here.</p>
      <% else %>
        <%= for run <- @runs do %>
          <div class="arcana-run-card">
            <div class="arcana-run-header">
              <div class="arcana-run-header-left">
                <span class={"arcana-run-status #{run.status}"}><%= run.status %></span>
                <span style="font-size: 0.875rem; color: #374151;">
                  <%= run.test_case_count %> test cases
                </span>
              </div>
              <div style="display: flex; gap: 0.5rem; align-items: center;">
                <span style="font-size: 0.75rem; color: #6b7280;"><%= run.inserted_at %></span>
                <button
                  style="background: transparent; color: #dc2626; border: 1px solid #dc2626; padding: 0.25rem 0.5rem; border-radius: 0.25rem; font-size: 0.75rem; cursor: pointer;"
                  phx-click="eval_delete_run"
                  phx-value-id={run.id}
                >
                  Delete
                </button>
              </div>
            </div>
            <div class="arcana-run-body">
              <div class="arcana-run-config">
                Mode: <strong><%= run.config["mode"] || run.config[:mode] || "vector" %></strong>
              </div>
              <%= if run.status == :completed and run.metrics do %>
                <div class="arcana-metrics-grid">
                  <div class="arcana-metric-card">
                    <div class="arcana-metric-value"><%= format_pct(run.metrics["recall_at_5"] || run.metrics[:recall_at_5]) %></div>
                    <div class="arcana-metric-label">Recall@5</div>
                  </div>
                  <div class="arcana-metric-card">
                    <div class="arcana-metric-value"><%= format_pct(run.metrics["precision_at_5"] || run.metrics[:precision_at_5]) %></div>
                    <div class="arcana-metric-label">Precision@5</div>
                  </div>
                  <div class="arcana-metric-card">
                    <div class="arcana-metric-value"><%= format_pct(run.metrics["mrr"] || run.metrics[:mrr]) %></div>
                    <div class="arcana-metric-label">MRR</div>
                  </div>
                  <div class="arcana-metric-card">
                    <div class="arcana-metric-value"><%= format_pct(run.metrics["hit_rate_at_5"] || run.metrics[:hit_rate_at_5]) %></div>
                    <div class="arcana-metric-label">Hit Rate@5</div>
                  </div>
                  <%= if run.metrics["faithfulness"] || run.metrics[:faithfulness] do %>
                    <div class="arcana-metric-card">
                      <div class="arcana-metric-value"><%= format_score(run.metrics["faithfulness"] || run.metrics[:faithfulness]) %></div>
                      <div class="arcana-metric-label">Faithfulness</div>
                    </div>
                  <% end %>
                  <%= if run.metrics["correctness"] || run.metrics[:correctness] do %>
                    <div class="arcana-metric-card">
                      <div class="arcana-metric-value"><%= format_score(run.metrics["correctness"] || run.metrics[:correctness]) %></div>
                      <div class="arcana-metric-label">Correctness</div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end
end
