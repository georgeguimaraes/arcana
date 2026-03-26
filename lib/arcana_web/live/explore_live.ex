defmodule ArcanaWeb.ExploreLive do
  @moduledoc """
  LiveView for LLM-driven document exploration (Recursive/RLM mode).
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(repo: get_repo_from_session(session))
     |> assign(
       explore_question: "",
       explore_running: false,
       explore_result: nil,
       explore_error: nil,
       explore_trace: [],
       explore_session_info: nil,
       max_steps: Arcana.Recursive.Session.default_max_steps(),
       selected_collections: [],
       expanded_trace_steps: MapSet.new(),
       collapsed_sessions: MapSet.new(),
       doc_ids: %{},
       stats: nil,
       collections: []
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    mode = parse_dashboard_mode(params["mode"])
    {:noreply, socket |> assign(mode: mode) |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo, socket.assigns.mode))
    |> assign(collections: load_collections(repo))
  end

  # --- Events ---

  @impl true
  def handle_event("explore_submit", params, socket) do
    question = String.trim(params["question"] || "")

    case {Application.get_env(:arcana, :llm), question} do
      {nil, _} ->
        {:noreply,
         assign(socket, explore_error: "No LLM configured. Set :arcana, :llm in your config.")}

      {_, ""} ->
        {:noreply, assign(socket, explore_error: "Please enter a question.")}

      {_llm, question} ->
        max_steps = parse_int(params["max_steps"], Arcana.Recursive.Session.default_max_steps())
        selected = params["collections"] || []

        socket =
          assign(socket,
            explore_running: true,
            explore_error: nil,
            explore_question: question,
            explore_result: nil,
            explore_trace: [],
            explore_session_info: nil,
            expanded_trace_steps: MapSet.new(),
            collapsed_sessions: MapSet.new(),
            max_steps: max_steps,
            selected_collections: selected
          )

        start_explore_task(socket, question)
        {:noreply, socket}
    end
  end

  def handle_event("explore_clear", _params, socket) do
    {:noreply,
     assign(socket,
       explore_result: nil,
       explore_error: nil,
       explore_question: "",
       explore_trace: [],
       explore_session_info: nil,
       expanded_trace_steps: MapSet.new(),
       collapsed_sessions: MapSet.new()
     )}
  end

  def handle_event("form_changed", params, socket) do
    selected = params["collections"] || []
    {:noreply, assign(socket, selected_collections: selected)}
  end

  def handle_event("toggle_trace_step", %{"step" => step_str}, socket) do
    step = String.to_integer(step_str)
    expanded = socket.assigns.expanded_trace_steps

    expanded =
      if MapSet.member?(expanded, step),
        do: MapSet.delete(expanded, step),
        else: MapSet.put(expanded, step)

    {:noreply, assign(socket, expanded_trace_steps: expanded)}
  end

  def handle_event("toggle_session", %{"session-id" => session_id}, socket) do
    collapsed = socket.assigns.collapsed_sessions

    collapsed =
      if MapSet.member?(collapsed, session_id),
        do: MapSet.delete(collapsed, session_id),
        else: MapSet.put(collapsed, session_id)

    {:noreply, assign(socket, collapsed_sessions: collapsed)}
  end

  # --- Task + Progress ---

  defp start_explore_task(socket, question) do
    parent = self()
    repo = socket.assigns.repo
    max_steps = socket.assigns.max_steps
    selected = socket.assigns.selected_collections
    model = Application.get_env(:arcana, :llm)

    handler_id = "explore-session-#{inspect(parent)}"

    :telemetry.attach(
      handler_id,
      [:arcana, :recursive, :session_init],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:explore_session_init, metadata})
      end,
      nil
    )

    collections = if selected == [], do: ["default"], else: selected

    Arcana.TaskSupervisor.start_child(fn ->
      result =
        Arcana.Recursive.explore(question,
          model: model,
          repo: repo,
          collections: collections,
          max_steps: max_steps,
          on_trace_entry: fn entry ->
            send(parent, {:explore_trace_entry, entry})
          end
        )

      :telemetry.detach(handler_id)
      send(parent, {:explore_complete, result})
    end)
  end

  @impl true
  def handle_info({:explore_session_init, metadata}, socket) do
    doc_ids = metadata[:doc_ids] || %{}
    {:noreply, assign(socket, explore_session_info: metadata, doc_ids: doc_ids)}
  end

  def handle_info({:explore_trace_entry, entry}, socket) do
    trace = socket.assigns.explore_trace ++ [entry]
    {:noreply, assign(socket, explore_trace: trace)}
  end

  def handle_info({:explore_complete, {:ok, result}}, socket) do
    # Keep the streamed trace (has child entries from sub_explores).
    # Only pull answer, usage, step_count from result.
    {:noreply,
     assign(socket,
       explore_running: false,
       explore_result: result
     )}
  end

  def handle_info({:explore_complete, {:error, reason}}, socket) do
    {:noreply,
     assign(socket,
       explore_running: false,
       explore_error: "Exploration failed: #{inspect(reason)}"
     )}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:explore} mode={@mode}>
      <div class="arcana-explore">
        <h2>Explore</h2>
        <p class="arcana-tab-description">
          LLM-driven document exploration. The model navigates your documents using grep and read_section tools.
        </p>

        <%= if @explore_error do %>
          <div class="arcana-eval-message error">
            <%= @explore_error %>
          </div>
        <% end %>

        <form id="explore-form" phx-submit="explore_submit" phx-change="form_changed" class="arcana-explore-form">
          <div class="arcana-explore-input">
            <textarea
              name="question"
              placeholder="Ask a question about your documents..."
              rows="3"
              disabled={@explore_running}
            ><%= @explore_question %></textarea>
          </div>

          <div class="arcana-explore-config">
            <label>
              Max steps
              <input
                type="number"
                name="max_steps"
                value={@max_steps}
                min="1"
                max="50"
                disabled={@explore_running}
              />
            </label>
          </div>

          <div class="arcana-ask-collections">
            <label>Collections</label>
            <div class="arcana-collection-checkboxes">
              <%= for coll <- @collections do %>
                <label class="arcana-collection-check">
                  <input
                    type="checkbox"
                    name="collections[]"
                    value={coll.name}
                    checked={coll.name in @selected_collections}
                    disabled={@explore_running}
                  />
                  <span><%= coll.name %></span>
                </label>
              <% end %>
            </div>
            <small class="arcana-collection-hint">Select none for all collections</small>
          </div>

          <div class="arcana-ask-actions">
            <button type="submit" class="arcana-explore-btn" disabled={@explore_running}>
              <%= if @explore_running, do: "Exploring...", else: "Explore" %>
            </button>
            <%= if @explore_result || @explore_trace != [] do %>
              <button type="button" phx-click="explore_clear" disabled={@explore_running}>
                Clear
              </button>
            <% end %>
          </div>
        </form>

        <%= if @explore_running or @explore_trace != [] do %>
          <div class="arcana-explore-trace">
            <h3>
              Tool Trace
              <%= if @explore_session_info do %>
                <span class="arcana-explore-session-info">
                  <%= @explore_session_info[:document_count] || 0 %> docs,
                  <%= @explore_session_info[:total_lines] || 0 %> lines
                </span>
              <% end %>
            </h3>

            <div class="arcana-explore-timeline">
              <%= if @explore_running and @explore_trace == [] do %>
                <div class="arcana-explore-trace-pending">
                  <div class="arcana-spinner"></div>
                  <span>Initializing...</span>
                </div>
              <% end %>

              <%= for {entry, idx} <- Enum.with_index(@explore_trace) do %>
                <% depth = entry[:depth] || 0 %>
                <% session_id = entry[:session_id] %>
                <% is_collapsed_child = session_id && session_id != "root" && MapSet.member?(@collapsed_sessions, session_id) %>
                <% child_session_id = get_in(entry, [:args, "child_session_id"]) %>

                <%= unless is_collapsed_child do %>
                  <div
                    class={"arcana-explore-trace-entry #{if depth > 0, do: "depth-#{min(depth, 3)}", else: ""}"}
                    style={"padding-left: #{depth * 1.5}rem"}
                  >
                    <div class="arcana-explore-trace-header" phx-click="toggle_trace_step" phx-value-step={idx}>
                      <span class="arcana-explore-step-num"><%= idx + 1 %></span>
                      <%= if depth > 0 do %>
                        <span class={"arcana-explore-depth-badge depth-#{min(depth, 3)}"}>D<%= depth %></span>
                      <% end %>
                      <span class={"arcana-explore-tool-badge #{entry.tool}"}><%= entry.tool %></span>
                      <span class="arcana-explore-tool-args"><%= Phoenix.HTML.raw(format_args(entry.tool, entry[:args] || entry[:arguments], @doc_ids, @mode)) %></span>
                      <%= if entry[:duration_ms] do %>
                        <span class="arcana-explore-duration"><%= entry.duration_ms %>ms</span>
                      <% end %>
                      <%= if child_session_id do %>
                        <span
                          class="arcana-explore-collapse-toggle"
                          phx-click="toggle_session"
                          phx-value-session-id={child_session_id}
                        >
                          <%= if MapSet.member?(@collapsed_sessions, child_session_id), do: "▶ show", else: "▼ hide" %>
                        </span>
                      <% end %>
                      <span class="arcana-explore-toggle"><%= if MapSet.member?(@expanded_trace_steps, idx), do: "▼", else: "▶" %></span>
                    </div>

                    <%= if MapSet.member?(@expanded_trace_steps, idx) do %>
                      <div class="arcana-explore-trace-detail">
                        <strong>Args</strong>
                        <pre><%= format_args_full(entry[:args] || entry[:arguments]) %></pre>
                        <strong>Result</strong>
                        <pre><%= entry[:result_preview] || entry[:result] || "" %></pre>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% end %>

              <%= if @explore_running and @explore_trace != [] do %>
                <div class="arcana-explore-trace-pending">
                  <div class="arcana-spinner"></div>
                  <span>Thinking...</span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @explore_result do %>
          <div class="arcana-explore-results">
            <div class="arcana-ask-answer">
              <h3>Answer</h3>
              <div class="arcana-answer-content">
                <%= @explore_result.answer %>
              </div>
            </div>

            <div class="arcana-explore-usage">
              <div>Steps: <span><%= @explore_result.step_count %></span></div>
              <div>Input tokens: <span><%= @explore_result.usage.input_tokens %></span></div>
              <div>Output tokens: <span><%= @explore_result.usage.output_tokens %></span></div>
            </div>
          </div>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  # --- Helpers ---

  defp format_args("grep", args, _doc_ids, _mode) when is_map(args) do
    pattern = Map.get(args, "pattern") || Map.get(args, :pattern, "")
    "pattern: \"#{esc(pattern)}\""
  end

  defp format_args("read_section", args, doc_ids, mode) when is_map(args) do
    doc = Map.get(args, "document") || Map.get(args, :document, "?")
    s = Map.get(args, "start_line") || Map.get(args, :start_line)
    e = Map.get(args, "end_line") || Map.get(args, :end_line)

    range =
      cond do
        s && e -> " [#{s}..#{e}]"
        s -> " [#{s}..end]"
        true -> ""
      end

    case Map.get(doc_ids, doc) do
      nil -> "#{esc(doc)}#{range}"
      doc_id -> doc_link(doc, doc_id, mode) <> range
    end
  end

  defp format_args("sub_explore", args, doc_ids, mode) when is_map(args) do
    task = Map.get(args, "task") || Map.get(args, :task, "")
    docs = Map.get(args, "documents") || Map.get(args, :documents, [])
    preview = String.slice(task, 0, 40)
    preview = if String.length(task) > 40, do: preview <> "...", else: preview

    linked_docs =
      docs
      |> Enum.map(fn name ->
        case Map.get(doc_ids, name) do
          nil -> esc(name)
          doc_id -> doc_link(name, doc_id, mode)
        end
      end)
      |> Enum.join(", ")

    "\"#{esc(preview)}\" (#{linked_docs})"
  end

  defp format_args(_tool, _args, _doc_ids, _mode), do: ""

  defp doc_link(name, doc_id, mode) do
    mode_str = if mode, do: "&mode=#{mode}", else: ""

    "<a href=\"/arcana/documents?doc=#{doc_id}#{mode_str}\" class=\"arcana-explore-doc-link\">#{esc(name)}</a>"
  end

  defp esc(text), do: Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()

  defp format_args_full(nil), do: "-"

  defp format_args_full(args) when is_map(args) do
    args
    |> Map.drop(["child_session_id"])
    |> inspect(pretty: true)
  end

  defp format_args_full(args), do: inspect(args, pretty: true)
end
