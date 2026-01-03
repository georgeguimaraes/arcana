defmodule ArcanaWeb.AskLive do
  @moduledoc """
  LiveView for asking questions about documents in Arcana.
  """
  use Phoenix.LiveView

  import Ecto.Query
  import ArcanaWeb.DashboardComponents

  alias Arcana.Graph.Entity

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       ask_mode: :simple,
       ask_question: "",
       ask_running: false,
       ask_context: nil,
       ask_error: nil,
       stats: nil,
       collections: [],
       graph_context_expanded: true,
       llm_select: false
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

  defp any_graph_enabled?(collections) do
    Enum.any?(collections, & &1[:graph_enabled])
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
        socket = assign(socket, ask_running: true, ask_error: nil, ask_question: question)
        start_ask_task(socket, params, llm, question)
        {:noreply, socket}
    end
  end

  def handle_event("ask_clear", _params, socket) do
    {:noreply, assign(socket, ask_context: nil, ask_error: nil, ask_question: "")}
  end

  def handle_event("ask_switch_mode", %{"mode" => mode}, socket) do
    mode = String.to_existing_atom(mode)
    # Reset llm_select when switching to simple mode
    llm_select = if mode == :simple, do: false, else: socket.assigns.llm_select
    {:noreply, assign(socket, ask_mode: mode, llm_select: llm_select)}
  end

  def handle_event("toggle_graph_context", _params, socket) do
    {:noreply, assign(socket, graph_context_expanded: !socket.assigns.graph_context_expanded)}
  end

  def handle_event("toggle_llm_select", _params, socket) do
    {:noreply, assign(socket, llm_select: !socket.assigns.llm_select)}
  end

  defp start_ask_task(socket, params, llm, question) do
    repo = socket.assigns.repo
    mode = params["mode"] || "simple"
    selected_collections = params["collections"] || []
    parent = self()

    Arcana.TaskSupervisor.start_child(fn ->
      result =
        run_ask(
          mode,
          question,
          repo,
          llm,
          socket.assigns.collections,
          params,
          selected_collections
        )

      send(parent, {:ask_complete, result})
    end)
  end

  defp run_ask("simple", question, repo, llm, _all_collections, _params, selected_collections) do
    run_simple_ask(question, repo, llm, selected_collections)
  end

  defp run_ask(_mode, question, repo, llm, all_collections, params, selected_collections) do
    run_agentic_ask(
      question,
      repo,
      llm,
      all_collections,
      collections: selected_collections,
      use_llm_select: params["llm_select"] == "true",
      use_expand: params["use_expand"] == "true",
      use_decompose: params["use_decompose"] == "true",
      use_rerank: params["use_rerank"] == "true",
      self_correct: params["self_correct"] == "true"
    )
  end

  @impl true
  def handle_info({:ask_complete, result}, socket) do
    socket =
      case result do
        {:ok, ctx} ->
          assign(socket, ask_running: false, ask_context: ctx, ask_error: nil)

        {:error, reason} ->
          assign(socket, ask_running: false, ask_error: inspect(reason))
      end

    {:noreply, socket}
  end

  defp run_simple_ask(question, repo, llm, selected_collections) do
    opts = [repo: repo, llm: llm]

    # Add collection(s) option if user selected any
    opts =
      case selected_collections do
        [] -> opts
        [single] -> Keyword.put(opts, :collection, single)
        multiple -> Keyword.put(opts, :collections, multiple)
      end

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

  defp run_agentic_ask(question, repo, llm, all_collections, opts) do
    alias Arcana.Agent

    all_collection_names = Enum.map(all_collections, & &1.name)
    search_opts = build_search_opts(opts, all_collection_names)

    Agent.new(question, repo: repo, llm: llm)
    |> maybe_select(opts, all_collection_names)
    |> maybe_expand(opts)
    |> maybe_decompose(opts)
    |> Agent.search(search_opts)
    |> maybe_rerank(opts)
    |> Agent.answer()
    |> format_agentic_result(question)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp maybe_select(ctx, opts, all_collection_names) do
    if Keyword.get(opts, :use_llm_select, false) and length(all_collection_names) > 1 do
      Arcana.Agent.select(ctx, collections: all_collection_names)
    else
      ctx
    end
  end

  defp maybe_expand(ctx, opts) do
    if Keyword.get(opts, :use_expand, false), do: Arcana.Agent.expand(ctx), else: ctx
  end

  defp maybe_decompose(ctx, opts) do
    if Keyword.get(opts, :use_decompose, false), do: Arcana.Agent.decompose(ctx), else: ctx
  end

  defp maybe_rerank(ctx, opts) do
    if Keyword.get(opts, :use_rerank, false), do: Arcana.Agent.rerank(ctx), else: ctx
  end

  defp build_search_opts(opts, all_collection_names) do
    base = [self_correct: Keyword.get(opts, :self_correct, false)]
    use_llm_select = Keyword.get(opts, :use_llm_select, false)

    if use_llm_select and length(all_collection_names) > 1 do
      base
    else
      add_collection_opts(base, Keyword.get(opts, :collections, []))
    end
  end

  defp add_collection_opts(opts, []), do: opts
  defp add_collection_opts(opts, [single]), do: Keyword.put(opts, :collection, single)
  defp add_collection_opts(opts, multiple), do: Keyword.put(opts, :collections, multiple)

  defp format_agentic_result(%{error: error}, _question) when not is_nil(error) do
    {:error, error}
  end

  defp format_agentic_result(ctx, question) do
    {:ok,
     %{
       question: question,
       answer: ctx.answer,
       results: ctx.results,
       expanded_query: ctx.expanded_query,
       sub_questions: ctx.sub_questions,
       selected_collections: ctx.collections
     }}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:ask}>
      <div class="arcana-ask">
        <h2>Ask</h2>
        <p class="arcana-tab-description">
          Ask questions about your documents. Choose Simple for basic RAG or Agentic for advanced pipeline features.
        </p>

        <div class="arcana-ask-mode-nav">
          <button
            class={"arcana-mode-btn #{if @ask_mode == :simple, do: "active", else: ""}"}
            phx-click="ask_switch_mode"
            phx-value-mode="simple"
          >
            Simple
          </button>
          <button
            class={"arcana-mode-btn #{if @ask_mode == :agentic, do: "active", else: ""}"}
            phx-click="ask_switch_mode"
            phx-value-mode="agentic"
          >
            Agentic
          </button>
        </div>

        <p class="arcana-mode-description">
          <%= if @ask_mode == :simple do %>
            Basic RAG: search for relevant chunks and generate an answer.
          <% else %>
            Advanced RAG: query expansion, decomposition, self-correction, and reranking.
          <% end %>
        </p>

        <%= if @ask_error do %>
          <div class="arcana-eval-message error">
            <%= @ask_error %>
          </div>
        <% end %>

        <form id="ask-form" phx-submit="ask_submit" class="arcana-ask-form">
          <input type="hidden" name="mode" value={@ask_mode} />

          <div class="arcana-ask-input">
            <textarea
              name="question"
              placeholder="Ask a question about your documents..."
              rows="3"
              disabled={@ask_running}
            ><%= @ask_question %></textarea>
          </div>

          <%= if any_graph_enabled?(@collections) do %>
            <div class="arcana-graph-toggle">
              <label class="arcana-checkbox-label">
                <input type="checkbox" name="graph_enhanced" value="true" disabled={@ask_running} />
                <span>Graph-Enhanced</span>
                <small>Uses entity/relationship context for better retrieval</small>
              </label>
            </div>
          <% end %>

          <div class="arcana-ask-collections">
            <label>Collections</label>
            <%= if @ask_mode == :agentic and length(@collections) > 1 do %>
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
                    <input type="checkbox" name="collections[]" value={coll.name} disabled={@ask_running} />
                    <span><%= coll.name %></span>
                  </label>
                <% end %>
              </div>
              <small class="arcana-collection-hint">Select none for all collections</small>
            <% end %>
          </div>

          <%= if @ask_mode == :agentic do %>
            <div class="arcana-ask-options">
              <h4>Pipeline Options</h4>
              <div class="arcana-option-grid">
                <label class="arcana-checkbox-label">
                  <input type="checkbox" name="use_expand" value="true" disabled={@ask_running} />
                  <span>Query Expansion</span>
                  <small>Generate related queries</small>
                </label>

                <label class="arcana-checkbox-label">
                  <input type="checkbox" name="use_decompose" value="true" disabled={@ask_running} />
                  <span>Question Decomposition</span>
                  <small>Break into sub-questions</small>
                </label>

                <label class="arcana-checkbox-label">
                  <input type="checkbox" name="self_correct" value="true" disabled={@ask_running} />
                  <span>Self-Correction</span>
                  <small>Refine search if results are poor</small>
                </label>

                <label class="arcana-checkbox-label">
                  <input type="checkbox" name="use_rerank" value="true" disabled={@ask_running} />
                  <span>Reranking</span>
                  <small>LLM-based result reranking</small>
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
            <span><%= if @ask_mode == :simple, do: "Generating answer...", else: "Running pipeline..." %></span>
          </div>
        <% end %>

        <%= if @ask_context do %>
          <div class="arcana-ask-results">
            <div class="arcana-ask-answer">
              <h3>Answer</h3>
              <div class="arcana-answer-content">
                <%= if @ask_context.answer do %>
                  <%= @ask_context.answer %>
                <% else %>
                  <span style="color: #9ca3af; font-style: italic;">No answer generated</span>
                <% end %>
              </div>
            </div>

            <%= if @ask_context.expanded_query do %>
              <div class="arcana-ask-section">
                <h4>Expanded Query</h4>
                <p class="arcana-expanded-query"><%= @ask_context.expanded_query %></p>
              </div>
            <% end %>

            <%= if @ask_context.sub_questions && length(@ask_context.sub_questions) > 0 do %>
              <div class="arcana-ask-section">
                <h4>Sub-Questions</h4>
                <ul class="arcana-query-list">
                  <%= for sq <- @ask_context.sub_questions do %>
                    <li><%= sq %></li>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <%= if @ask_context.selected_collections && length(@ask_context.selected_collections) > 0 do %>
              <div class="arcana-ask-section">
                <h4>Selected Collections</h4>
                <div class="arcana-collection-badges">
                  <%= for coll <- @ask_context.selected_collections do %>
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

            <%= if @ask_context.results && length(@ask_context.results) > 0 do %>
              <% all_chunks = @ask_context.results %>
              <div class="arcana-ask-section">
                <h4>Retrieved Chunks (<%= length(all_chunks) %>)</h4>
                <div class="arcana-search-results">
                  <%= for chunk <- all_chunks do %>
                    <div class="arcana-search-result">
                      <div class="arcana-result-header">
                        <div class="arcana-result-score">
                          <span class="score-value"><%= Float.round(chunk.score, 4) %></span>
                          <%= if Map.get(chunk, :graph_sources) && length(chunk.graph_sources) > 0 do %>
                            <span class="arcana-graph-attribution">
                              via: <%= Enum.join(chunk.graph_sources, ", ") %>
                            </span>
                          <% end %>
                        </div>
                        <div class="arcana-result-meta">
                          <code><%= chunk.document_id %></code>
                          <span class="arcana-chunk-badge">Chunk <%= chunk.chunk_index %></span>
                        </div>
                      </div>
                      <div class="arcana-result-text">
                        <%= String.slice(chunk.text, 0, 300) %><%= if String.length(chunk.text) > 300, do: "...", else: "" %>
                      </div>
                    </div>
                  <% end %>
                </div>
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
end
