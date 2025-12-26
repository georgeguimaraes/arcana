defmodule ArcanaWeb.DashboardLive do
  @moduledoc """
  LiveView for the Arcana dashboard.

  Provides tabs for managing documents and searching.
  """
  use Phoenix.LiveView

  alias Arcana.Document
  alias Arcana.Evaluation

  @impl true
  def mount(_params, session, socket) do
    repo = session["repo"] || Arcana.TestRepo

    socket =
      socket
      |> assign(tab: :documents, repo: repo)
      |> assign(search_results: [], search_query: "")
      |> assign(page: 1, per_page: 10)
      |> assign(viewing_document: nil)
      |> assign(eval_view: :test_cases, eval_running: false, eval_message: nil)
      |> load_documents()
      |> load_source_ids()
      |> load_stats()
      |> load_evaluation_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, tab: String.to_existing_atom(tab))}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)
    {:noreply, socket |> assign(page: page) |> load_documents()}
  end

  def handle_event("view_document", %{"id" => id}, socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    document = repo.get(Document, id)

    chunks =
      repo.all(
        from(c in Arcana.Chunk,
          where: c.document_id == ^id,
          order_by: c.chunk_index
        )
      )

    {:noreply, assign(socket, viewing_document: %{document: document, chunks: chunks})}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, viewing_document: nil)}
  end

  def handle_event("ingest", params, socket) do
    repo = socket.assigns.repo
    content = params["content"] || ""
    format = parse_format(params["format"])

    {:ok, _doc} = Arcana.ingest(content, repo: repo, format: format)
    {:noreply, socket |> load_documents() |> load_stats()}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case Arcana.delete(id, repo: repo) do
      :ok ->
        {:noreply, socket |> load_documents() |> load_stats()}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("search", params, socket) do
    repo = socket.assigns.repo
    query = params["query"] || ""
    limit = parse_int(params["limit"], 10)
    threshold = parse_float(params["threshold"], 0.0)
    source_id = if params["source_id"] in [nil, ""], do: nil, else: params["source_id"]
    mode = parse_mode(params["mode"])

    results =
      if query != "" do
        opts = [repo: repo, limit: limit, threshold: threshold, mode: mode]
        opts = if source_id, do: Keyword.put(opts, :source_id, source_id), else: opts
        Arcana.search(query, opts)
      else
        []
      end

    {:noreply, assign(socket, search_results: results, search_query: query)}
  end

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

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_float(nil, default), do: default
  defp parse_float("", default), do: default

  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  defp parse_mode("semantic"), do: :semantic
  defp parse_mode("fulltext"), do: :fulltext
  defp parse_mode("hybrid"), do: :hybrid
  defp parse_mode(_), do: :semantic

  defp parse_format("plaintext"), do: :plaintext
  defp parse_format("markdown"), do: :markdown
  defp parse_format("elixir"), do: :elixir
  defp parse_format(_), do: :plaintext

  defp format_metadata(nil), do: "-"
  defp format_metadata(metadata) when metadata == %{}, do: "-"

  defp format_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
  end

  defp load_documents(socket) do
    repo = socket.assigns.repo
    page = socket.assigns.page
    per_page = socket.assigns.per_page
    import Ecto.Query

    total_count = repo.aggregate(Document, :count)
    total_pages = max(1, ceil(total_count / per_page))

    documents =
      repo.all(
        from(d in Document,
          order_by: [desc: d.inserted_at],
          offset: ^((page - 1) * per_page),
          limit: ^per_page
        )
      )

    assign(socket,
      documents: documents,
      total_pages: total_pages,
      total_count: total_count
    )
  end

  defp load_source_ids(socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    source_ids =
      repo.all(
        from(d in Document,
          where: not is_nil(d.source_id),
          distinct: d.source_id,
          select: d.source_id
        )
      )

    assign(socket, source_ids: source_ids)
  end

  defp load_stats(socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    doc_count = repo.aggregate(Document, :count)

    chunk_count =
      repo.one(from(c in Arcana.Chunk, select: count(c.id))) || 0

    assign(socket, stats: %{documents: doc_count, chunks: chunk_count})
  end

  defp load_evaluation_data(socket) do
    repo = socket.assigns.repo

    test_cases = Evaluation.list_test_cases(repo: repo)
    runs = Evaluation.list_runs(repo: repo, limit: 10)
    test_case_count = Evaluation.count_test_cases(repo: repo)

    assign(socket,
      eval_test_cases: test_cases,
      eval_runs: runs,
      eval_test_case_count: test_case_count
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      .arcana-dashboard {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        max-width: 1200px;
        margin: 0 auto;
        padding: 1.5rem;
        color: #1f2937;
      }

      .arcana-tabs {
        display: flex;
        gap: 0.5rem;
        border-bottom: 2px solid #e5e7eb;
        margin-bottom: 1.5rem;
      }

      .arcana-tab {
        padding: 0.75rem 1.5rem;
        border: none;
        background: transparent;
        font-size: 1rem;
        font-weight: 500;
        color: #6b7280;
        cursor: pointer;
        border-bottom: 2px solid transparent;
        margin-bottom: -2px;
        transition: all 0.15s ease;
      }

      .arcana-tab:hover {
        color: #7c3aed;
      }

      .arcana-tab.active {
        color: #7c3aed;
        border-bottom-color: #7c3aed;
      }

      .arcana-dashboard h2 {
        font-size: 1.5rem;
        font-weight: 600;
        color: #111827;
        margin: 0 0 1rem 0;
      }

      .arcana-ingest-form,
      .arcana-search-form {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1.5rem;
      }

      .arcana-ingest-form textarea,
      .arcana-search-form input[type="text"] {
        width: 100%;
        padding: 0.75rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        margin-bottom: 0.75rem;
        box-sizing: border-box;
      }

      .arcana-ingest-form textarea:focus,
      .arcana-search-form input:focus,
      .arcana-search-form select:focus {
        outline: none;
        border-color: #7c3aed;
        box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
      }

      .arcana-search-options {
        display: flex;
        gap: 1rem;
        flex-wrap: wrap;
        margin-bottom: 0.75rem;
      }

      .arcana-search-options label {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
      }

      .arcana-search-options select,
      .arcana-search-options input[type="number"] {
        padding: 0.5rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        min-width: 100px;
      }

      .arcana-ingest-form button,
      .arcana-search-form button {
        background: #7c3aed;
        color: white;
        padding: 0.625rem 1.25rem;
        border: none;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        font-weight: 500;
        cursor: pointer;
        transition: background-color 0.15s ease;
      }

      .arcana-ingest-form button:hover,
      .arcana-search-form button:hover {
        background: #6d28d9;
      }

      .arcana-ingest-options {
        display: flex;
        gap: 1rem;
        margin-bottom: 0.75rem;
      }

      .arcana-ingest-options label {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
      }

      .arcana-ingest-options select {
        padding: 0.5rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        min-width: 120px;
      }

      .arcana-ingest-options select:focus {
        outline: none;
        border-color: #7c3aed;
        box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
      }

      .arcana-empty {
        color: #6b7280;
        font-style: italic;
        padding: 2rem;
        text-align: center;
        background: #f9fafb;
        border-radius: 0.5rem;
      }

      .arcana-documents-table,
      .arcana-results-table {
        width: 100%;
        border-collapse: collapse;
        font-size: 0.875rem;
      }

      .arcana-documents-table th,
      .arcana-results-table th {
        text-align: left;
        padding: 0.75rem;
        background: #f3f4f6;
        border-bottom: 2px solid #e5e7eb;
        font-weight: 600;
        color: #374151;
      }

      .arcana-documents-table td,
      .arcana-results-table td {
        padding: 0.75rem;
        border-bottom: 1px solid #e5e7eb;
        vertical-align: top;
      }

      .arcana-documents-table tr:hover,
      .arcana-results-table tr:hover {
        background: #f9fafb;
      }

      .arcana-documents-table code,
      .arcana-results-table code {
        font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
        font-size: 0.75rem;
        background: #ede9fe;
        color: #6d28d9;
        padding: 0.125rem 0.375rem;
        border-radius: 0.25rem;
      }

      .arcana-documents-table button {
        background: transparent;
        color: #dc2626;
        border: 1px solid #dc2626;
        padding: 0.375rem 0.75rem;
        border-radius: 0.25rem;
        font-size: 0.75rem;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .arcana-documents-table button:hover {
        background: #dc2626;
        color: white;
      }

      .arcana-metadata {
        font-size: 0.75rem;
        color: #6b7280;
        max-width: 200px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }

      .arcana-stats {
        display: flex;
        gap: 1.5rem;
        margin-bottom: 1.5rem;
        padding: 1rem;
        background: linear-gradient(135deg, #7c3aed 0%, #6d28d9 100%);
        border-radius: 0.5rem;
        color: white;
      }

      .arcana-stat {
        text-align: center;
      }

      .arcana-stat-value {
        font-size: 1.5rem;
        font-weight: 700;
      }

      .arcana-stat-label {
        font-size: 0.75rem;
        opacity: 0.9;
        text-transform: uppercase;
        letter-spacing: 0.05em;
      }

      .arcana-pagination {
        display: flex;
        gap: 0.5rem;
        justify-content: center;
        margin-top: 1rem;
        padding-top: 1rem;
        border-top: 1px solid #e5e7eb;
      }

      .arcana-page-btn {
        padding: 0.5rem 0.75rem;
        border: 1px solid #d1d5db;
        background: white;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .arcana-page-btn:hover {
        border-color: #7c3aed;
        color: #7c3aed;
      }

      .arcana-page-btn.active {
        background: #7c3aed;
        border-color: #7c3aed;
        color: white;
      }

      .arcana-actions {
        display: flex;
        gap: 0.5rem;
      }

      .arcana-view-btn {
        background: transparent;
        color: #7c3aed;
        border: 1px solid #7c3aed;
      }

      .arcana-view-btn:hover {
        background: #7c3aed;
        color: white;
      }

      .arcana-doc-detail {
        background: white;
      }

      .arcana-doc-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 1.5rem;
      }

      .arcana-doc-header h2 {
        margin: 0;
      }

      .arcana-close-btn {
        background: transparent;
        color: #6b7280;
        border: 1px solid #d1d5db;
        padding: 0.5rem 1rem;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .arcana-close-btn:hover {
        border-color: #7c3aed;
        color: #7c3aed;
      }

      .arcana-doc-info {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
        gap: 1rem;
        background: #f9fafb;
        padding: 1rem;
        border-radius: 0.5rem;
        margin-bottom: 1.5rem;
      }

      .arcana-doc-field label {
        display: block;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
        margin-bottom: 0.25rem;
      }

      .arcana-doc-section {
        margin-bottom: 1.5rem;
      }

      .arcana-doc-section h3 {
        font-size: 1rem;
        font-weight: 600;
        color: #374151;
        margin: 0 0 0.75rem 0;
      }

      .arcana-doc-content {
        background: #f9fafb;
        padding: 1rem;
        border-radius: 0.5rem;
        font-size: 0.875rem;
        white-space: pre-wrap;
        word-wrap: break-word;
        margin: 0;
        max-height: 300px;
        overflow-y: auto;
      }

      .arcana-chunks-list {
        display: flex;
        flex-direction: column;
        gap: 1rem;
      }

      .arcana-chunk {
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        overflow: hidden;
      }

      .arcana-chunk-header {
        display: flex;
        justify-content: space-between;
        padding: 0.5rem 1rem;
        background: #f3f4f6;
        font-size: 0.75rem;
        font-weight: 500;
      }

      .arcana-chunk-index {
        color: #7c3aed;
      }

      .arcana-chunk-tokens {
        color: #6b7280;
      }

      .arcana-chunk-text {
        padding: 1rem;
        margin: 0;
        font-size: 0.875rem;
        white-space: pre-wrap;
        word-wrap: break-word;
        background: white;
      }

      /* Evaluation tab styles */
      .arcana-eval-nav {
        display: flex;
        gap: 0.5rem;
        margin-bottom: 1.5rem;
      }

      .arcana-eval-nav-btn {
        padding: 0.5rem 1rem;
        border: 1px solid #d1d5db;
        background: white;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        cursor: pointer;
        transition: all 0.15s ease;
      }

      .arcana-eval-nav-btn:hover {
        border-color: #7c3aed;
        color: #7c3aed;
      }

      .arcana-eval-nav-btn.active {
        background: #7c3aed;
        border-color: #7c3aed;
        color: white;
      }

      .arcana-eval-message {
        padding: 0.75rem 1rem;
        border-radius: 0.375rem;
        margin-bottom: 1rem;
        font-size: 0.875rem;
      }

      .arcana-eval-message.success {
        background: #d1fae5;
        color: #065f46;
        border: 1px solid #a7f3d0;
      }

      .arcana-eval-message.error {
        background: #fee2e2;
        color: #991b1b;
        border: 1px solid #fecaca;
      }

      .arcana-run-form {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1.5rem;
        display: flex;
        gap: 1rem;
        align-items: flex-end;
      }

      .arcana-run-form label {
        display: flex;
        flex-direction: column;
        gap: 0.25rem;
        font-size: 0.75rem;
        font-weight: 500;
        color: #6b7280;
      }

      .arcana-run-form select {
        padding: 0.5rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        min-width: 120px;
      }

      .arcana-run-form button {
        background: #7c3aed;
        color: white;
        padding: 0.625rem 1.25rem;
        border: none;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        font-weight: 500;
        cursor: pointer;
        transition: background-color 0.15s ease;
      }

      .arcana-run-form button:hover {
        background: #6d28d9;
      }

      .arcana-run-form button:disabled {
        background: #9ca3af;
        cursor: not-allowed;
      }

      .arcana-metrics-grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
        gap: 1rem;
        margin-bottom: 1.5rem;
      }

      .arcana-metric-card {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        text-align: center;
      }

      .arcana-metric-value {
        font-size: 1.5rem;
        font-weight: 700;
        color: #7c3aed;
      }

      .arcana-metric-label {
        font-size: 0.75rem;
        color: #6b7280;
        margin-top: 0.25rem;
      }

      .arcana-test-case {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 0.75rem;
      }

      .arcana-test-case-header {
        display: flex;
        justify-content: space-between;
        align-items: flex-start;
        margin-bottom: 0.5rem;
      }

      .arcana-test-case-question {
        font-weight: 500;
        color: #111827;
      }

      .arcana-test-case-meta {
        display: flex;
        gap: 1rem;
        font-size: 0.75rem;
        color: #6b7280;
      }

      .arcana-test-case-badge {
        display: inline-block;
        padding: 0.125rem 0.5rem;
        border-radius: 9999px;
        font-size: 0.625rem;
        font-weight: 500;
        text-transform: uppercase;
      }

      .arcana-test-case-badge.synthetic {
        background: #ddd6fe;
        color: #5b21b6;
      }

      .arcana-test-case-badge.manual {
        background: #bfdbfe;
        color: #1e40af;
      }

      .arcana-run-card {
        background: white;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        margin-bottom: 1rem;
        overflow: hidden;
      }

      .arcana-run-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 0.75rem 1rem;
        background: #f3f4f6;
        border-bottom: 1px solid #e5e7eb;
      }

      .arcana-run-header-left {
        display: flex;
        align-items: center;
        gap: 0.75rem;
      }

      .arcana-run-status {
        padding: 0.25rem 0.75rem;
        border-radius: 9999px;
        font-size: 0.75rem;
        font-weight: 500;
      }

      .arcana-run-status.completed {
        background: #d1fae5;
        color: #065f46;
      }

      .arcana-run-status.running {
        background: #fef3c7;
        color: #92400e;
      }

      .arcana-run-status.failed {
        background: #fee2e2;
        color: #991b1b;
      }

      .arcana-run-body {
        padding: 1rem;
      }

      .arcana-run-config {
        font-size: 0.75rem;
        color: #6b7280;
        margin-bottom: 0.75rem;
      }
    </style>
    <div class="arcana-dashboard">
      <div class="arcana-stats">
        <div class="arcana-stat">
          <div class="arcana-stat-value"><%= @stats.documents %></div>
          <div class="arcana-stat-label">Documents</div>
        </div>
        <div class="arcana-stat">
          <div class="arcana-stat-value"><%= @stats.chunks %></div>
          <div class="arcana-stat-label">Chunks</div>
        </div>
      </div>

      <nav class="arcana-tabs">
        <button
          data-tab="documents"
          class={"arcana-tab #{if @tab == :documents, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="documents"
        >
          Documents
        </button>
        <button
          data-tab="search"
          class={"arcana-tab #{if @tab == :search, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="search"
        >
          Search
        </button>
        <button
          data-tab="evaluation"
          class={"arcana-tab #{if @tab == :evaluation, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="evaluation"
        >
          Evaluation
        </button>
      </nav>

      <div class="arcana-content">
        <%= case @tab do %>
          <% :documents -> %>
            <.documents_tab documents={@documents} page={@page} total_pages={@total_pages} viewing={@viewing_document} />
          <% :search -> %>
            <.search_tab results={@search_results} query={@search_query} source_ids={@source_ids} />
          <% :evaluation -> %>
            <.evaluation_tab
              view={@eval_view}
              test_cases={@eval_test_cases}
              runs={@eval_runs}
              test_case_count={@eval_test_case_count}
              running={@eval_running}
              message={@eval_message}
            />
        <% end %>
      </div>
    </div>
    """
  end

  defp documents_tab(assigns) do
    ~H"""
    <div class="arcana-documents">
      <%= if @viewing do %>
        <.document_detail viewing={@viewing} />
      <% else %>
      <h2>Documents</h2>

      <form id="ingest-form" phx-submit="ingest" class="arcana-ingest-form">
        <textarea name="content" placeholder="Paste text to ingest..." rows="4"></textarea>
        <div class="arcana-ingest-options">
          <label>
            Format
            <select name="format">
              <option value="plaintext">Plaintext</option>
              <option value="markdown">Markdown</option>
              <option value="elixir">Elixir</option>
            </select>
          </label>
        </div>
        <button type="submit">Ingest</button>
      </form>

      <%= if Enum.empty?(@documents) do %>
        <p class="arcana-empty">No documents yet. Paste some text above to get started.</p>
      <% else %>
        <table class="arcana-documents-table">
          <thead>
            <tr>
              <th>ID</th>
              <th>Content</th>
              <th>Source</th>
              <th>Metadata</th>
              <th>Chunks</th>
              <th>Created</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            <%= for doc <- @documents do %>
              <tr>
                <td><code><%= doc.id %></code></td>
                <td><%= String.slice(doc.content || "", 0, 100) %>...</td>
                <td><%= doc.source_id || "-" %></td>
                <td class="arcana-metadata"><%= format_metadata(doc.metadata) %></td>
                <td><%= doc.chunk_count %></td>
                <td><%= doc.inserted_at %></td>
                <td class="arcana-actions">
                  <button
                    data-view-doc={doc.id}
                    class="arcana-view-btn"
                    phx-click="view_document"
                    phx-value-id={doc.id}
                  >
                    View
                  </button>
                  <button
                    data-delete-doc={doc.id}
                    phx-click="delete"
                    phx-value-id={doc.id}
                  >
                    Delete
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%= if @total_pages > 1 do %>
          <div class="arcana-pagination">
            <%= for page <- 1..@total_pages do %>
              <button
                data-page={page}
                class={"arcana-page-btn #{if page == @page, do: "active", else: ""}"}
                phx-click="change_page"
                phx-value-page={page}
              >
                <%= page %>
              </button>
            <% end %>
          </div>
        <% end %>
      <% end %>
      <% end %>
    </div>
    """
  end

  defp document_detail(assigns) do
    ~H"""
    <div class="arcana-doc-detail">
      <div class="arcana-doc-header">
        <h2>Document Details</h2>
        <button class="arcana-close-btn" phx-click="close_detail">← Back to list</button>
      </div>

      <div class="arcana-doc-info">
        <div class="arcana-doc-field">
          <label>ID</label>
          <code><%= @viewing.document.id %></code>
        </div>
        <div class="arcana-doc-field">
          <label>Source</label>
          <span><%= @viewing.document.source_id || "-" %></span>
        </div>
        <div class="arcana-doc-field">
          <label>Metadata</label>
          <span><%= format_metadata(@viewing.document.metadata) %></span>
        </div>
        <div class="arcana-doc-field">
          <label>Created</label>
          <span><%= @viewing.document.inserted_at %></span>
        </div>
      </div>

      <div class="arcana-doc-section">
        <h3>Full Content</h3>
        <pre class="arcana-doc-content"><%= @viewing.document.content %></pre>
      </div>

      <div class="arcana-doc-section">
        <h3>Chunks (<%= length(@viewing.chunks) %>)</h3>
        <div class="arcana-chunks-list">
          <%= for chunk <- @viewing.chunks do %>
            <div class="arcana-chunk">
              <div class="arcana-chunk-header">
                <span class="arcana-chunk-index">Chunk <%= chunk.chunk_index %></span>
                <span class="arcana-chunk-tokens"><%= chunk.token_count %> tokens</span>
              </div>
              <pre class="arcana-chunk-text"><%= chunk.text %></pre>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp search_tab(assigns) do
    ~H"""
    <div class="arcana-search">
      <h2>Search</h2>

      <form id="search-form" phx-submit="search" class="arcana-search-form">
        <div class="arcana-search-inputs">
          <input type="text" name="query" placeholder="Enter search query..." value={@query} />

          <div class="arcana-search-options">
            <label>
              Mode
              <select name="mode">
                <option value="semantic">Semantic</option>
                <option value="fulltext">Full-text</option>
                <option value="hybrid">Hybrid</option>
              </select>
            </label>

            <label>
              Limit
              <select name="limit">
                <option value="5">5</option>
                <option value="10" selected>10</option>
                <option value="20">20</option>
                <option value="50">50</option>
              </select>
            </label>

            <label>
              Threshold
              <input type="number" name="threshold" min="0" max="1" step="0.1" value="0" />
            </label>

            <label>
              Source
              <select name="source_id">
                <option value="">All sources</option>
                <%= for source_id <- @source_ids do %>
                  <option value={source_id}><%= source_id %></option>
                <% end %>
              </select>
            </label>
          </div>
        </div>

        <button type="submit">Search</button>
      </form>

      <%= if Enum.empty?(@results) and @query != "" do %>
        <p class="arcana-empty">No results found for "<%= @query %>"</p>
      <% end %>

      <%= if not Enum.empty?(@results) do %>
        <table class="arcana-results-table">
          <thead>
            <tr>
              <th>Score</th>
              <th>Text</th>
              <th>Document ID</th>
              <th>Chunk Index</th>
            </tr>
          </thead>
          <tbody>
            <%= for result <- @results do %>
              <tr>
                <td><%= Float.round(result.score, 4) %></td>
                <td><%= String.slice(result.text, 0, 200) %>...</td>
                <td><code><%= result.document_id %></code></td>
                <td><%= result.chunk_index %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  defp evaluation_tab(assigns) do
    ~H"""
    <div class="arcana-evaluation">
      <h2>Retrieval Evaluation</h2>

      <div class="arcana-eval-nav">
        <button
          class={"arcana-eval-nav-btn #{if @view == :test_cases, do: "active", else: ""}"}
          phx-click="eval_switch_view"
          phx-value-view="test_cases"
        >
          Test Cases (<%= @test_case_count %>)
        </button>
        <button
          class={"arcana-eval-nav-btn #{if @view == :run, do: "active", else: ""}"}
          phx-click="eval_switch_view"
          phx-value-view="run"
        >
          Run Evaluation
        </button>
        <button
          class={"arcana-eval-nav-btn #{if @view == :history, do: "active", else: ""}"}
          phx-click="eval_switch_view"
          phx-value-view="history"
        >
          History (<%= length(@runs) %>)
        </button>
      </div>

      <%= if @message do %>
        <div class={"arcana-eval-message #{elem(@message, 0)}"}>
          <%= elem(@message, 1) %>
        </div>
      <% end %>

      <%= case @view do %>
        <% :test_cases -> %>
          <.eval_test_cases_view test_cases={@test_cases} />
        <% :run -> %>
          <.eval_run_view running={@running} test_case_count={@test_case_count} />
        <% :history -> %>
          <.eval_history_view runs={@runs} />
      <% end %>
    </div>
    """
  end

  defp eval_test_cases_view(assigns) do
    ~H"""
    <div class="arcana-eval-test-cases">
      <%= if Enum.empty?(@test_cases) do %>
        <p class="arcana-empty">
          No test cases yet. Use <code>mix arcana.eval.generate</code> to generate synthetic test cases,
          or create them via the API.
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

  defp format_pct(nil), do: "-"
  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(value) when is_integer(value), do: "#{value}%"
end
