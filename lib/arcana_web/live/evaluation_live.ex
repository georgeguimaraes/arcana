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
       eval_message: nil
     )
     |> load_data()}
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
    {:noreply, assign(socket, eval_view: String.to_existing_atom(view))}
  end

  def handle_event("eval_run", params, socket) do
    repo = socket.assigns.repo
    mode = parse_mode(params["mode"])

    socket = assign(socket, eval_running: true, eval_message: nil)

    case Evaluation.run(repo: repo, mode: mode) do
      {:ok, _run} ->
        socket =
          socket
          |> assign(eval_running: false, eval_message: {:success, "Evaluation completed!"})
          |> load_evaluation_data()
          |> assign(eval_view: :history)

        {:noreply, socket}

      {:error, :no_test_cases} ->
        {:noreply,
         assign(socket,
           eval_running: false,
           eval_message: {:error, "No test cases. Generate some first."}
         )}
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

        Task.start(fn ->
          result = Evaluation.generate_test_cases(opts)
          send(parent, {:eval_generate_complete, result})
        end)

        {:noreply, socket}
    end
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

  defp build_generate_opts(repo, llm, sample_size, nil) do
    [repo: repo, llm: llm, sample_size: sample_size]
  end

  defp build_generate_opts(repo, llm, sample_size, collection) do
    [repo: repo, llm: llm, sample_size: sample_size, collection: collection]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:evaluation}>
      <div class="arcana-evaluation">
        <h2>Retrieval Evaluation</h2>

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
            <.eval_test_cases_view test_cases={@eval_test_cases} generating={@eval_generating} collections={@collections} />
          <% :run -> %>
            <.eval_run_view running={@eval_running} test_case_count={@eval_test_case_count} />
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
      <form phx-submit="eval_generate" class="arcana-run-form" style="margin-bottom: 1.5rem;">
        <label>
          Collection
          <select name="collection">
            <option value="">All collections</option>
            <%= for col <- @collections do %>
              <option value={col.name}><%= col.name %></option>
            <% end %>
          </select>
        </label>

        <label>
          Sample Size
          <select name="sample_size">
            <option value="5">5</option>
            <option value="10" selected>10</option>
            <option value="25">25</option>
            <option value="50">50</option>
            <option value="100">100</option>
          </select>
        </label>

        <button type="submit" disabled={@generating}>
          <%= if @generating, do: "Generating...", else: "Generate Test Cases" %>
        </button>

        <span style="font-size: 0.75rem; color: #6b7280; align-self: center;">
          Samples random chunks and uses the configured LLM to generate questions
        </span>
      </form>

      <%= if Enum.empty?(@test_cases) do %>
        <p class="arcana-empty">
          No test cases yet. Click "Generate Test Cases" above or use the API.
        </p>
      <% else %>
        <%= for tc <- @test_cases do %>
          <div class="arcana-test-case">
            <div class="arcana-test-case-header">
              <span class="arcana-test-case-question"><%= tc.question %></span>
              <button
                class="arcana-documents-table button"
                phx-click="eval_delete_test_case"
                phx-value-id={tc.id}
                style="padding: 0.25rem 0.5rem; font-size: 0.75rem;"
              >
                Delete
              </button>
            </div>
            <div class="arcana-test-case-meta">
              <span class={"arcana-test-case-badge #{tc.source}"}><%= tc.source %></span>
              <span><%= length(tc.relevant_chunks) %> relevant chunk(s)</span>
              <span><%= tc.inserted_at %></span>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp eval_run_view(assigns) do
    ~H"""
    <div class="arcana-eval-run">
      <p style="margin-bottom: 1rem; color: #6b7280;">
        Run evaluation against your <%= @test_case_count %> test case(s) to measure retrieval quality.
      </p>

      <form phx-submit="eval_run" class="arcana-run-form">
        <label>
          Search Mode
          <select name="mode">
            <option value="semantic">Semantic</option>
            <option value="fulltext">Full-text</option>
            <option value="hybrid">Hybrid</option>
          </select>
        </label>

        <button type="submit" disabled={@running or @test_case_count == 0}>
          <%= if @running, do: "Running...", else: "Run Evaluation" %>
        </button>
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
                Mode: <strong><%= run.config["mode"] || run.config[:mode] || "semantic" %></strong>
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
