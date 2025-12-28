defmodule ArcanaWeb.DashboardComponents do
  @moduledoc """
  Shared components for the Arcana dashboard.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders the dashboard layout with stats bar, navigation, and content.
  """
  attr(:stats, :map, required: true)
  attr(:current_tab, :atom, required: true)
  slot(:inner_block, required: true)

  def dashboard_layout(assigns) do
    ~H"""
    <style><%= raw(css()) %></style>
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
        <.nav_link href="/arcana/documents" active={@current_tab == :documents}>Documents</.nav_link>
        <.nav_link href="/arcana/collections" active={@current_tab == :collections}>Collections</.nav_link>
        <.nav_link href="/arcana/search" active={@current_tab == :search}>Search</.nav_link>
        <.nav_link href="/arcana/evaluation" active={@current_tab == :evaluation}>Evaluation</.nav_link>
        <.nav_link href="/arcana/maintenance" active={@current_tab == :maintenance}>Maintenance</.nav_link>
        <.nav_link href="/arcana/info" active={@current_tab == :info}>Info</.nav_link>
      </nav>

      <div class="arcana-content">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  attr(:href, :string, required: true)
  attr(:active, :boolean, default: false)
  slot(:inner_block, required: true)

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class={"arcana-tab #{if @active, do: "active", else: ""}"}>
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  # Helper functions shared across dashboard pages
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  def parse_float(nil, default), do: default
  def parse_float("", default), do: default

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  def parse_mode("semantic"), do: :semantic
  def parse_mode("fulltext"), do: :fulltext
  def parse_mode("hybrid"), do: :hybrid
  def parse_mode(_), do: :semantic

  def parse_format("plaintext"), do: :plaintext
  def parse_format("markdown"), do: :markdown
  def parse_format("elixir"), do: :elixir
  def parse_format(_), do: :plaintext

  def normalize_collection(""), do: "default"
  def normalize_collection(nil), do: "default"
  def normalize_collection(name) when is_binary(name), do: name

  def blank_to_nil(""), do: nil
  def blank_to_nil(nil), do: nil
  def blank_to_nil(value), do: value

  def format_metadata(nil), do: "-"
  def format_metadata(metadata) when metadata == %{}, do: "-"

  def format_metadata(metadata) when is_map(metadata) do
    Enum.map_join(metadata, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  def format_pct(nil), do: "-"
  def format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  def format_pct(value) when is_integer(value), do: "#{value}%"

  def format_score(nil), do: "-"
  def format_score(value) when is_float(value), do: "#{Float.round(value, 1)}/10"
  def format_score(value) when is_integer(value), do: "#{value}/10"

  def error_to_string(:too_large), do: "File too large (max 10MB)"
  def error_to_string(:too_many_files), do: "Too many files (max 10)"
  def error_to_string(:not_accepted), do: "File type not supported"
  def error_to_string(err), do: "Error: #{inspect(err)}"

  # Shared data loading functions
  def load_stats(repo) do
    import Ecto.Query

    doc_count = repo.aggregate(Arcana.Document, :count)
    chunk_count = repo.one(from(c in Arcana.Chunk, select: count(c.id))) || 0

    %{documents: doc_count, chunks: chunk_count}
  end

  def load_collections(repo) do
    import Ecto.Query

    repo.all(
      from(c in Arcana.Collection,
        left_join: d in Arcana.Document,
        on: d.collection_id == c.id,
        group_by: c.id,
        order_by: c.name,
        select: %{
          id: c.id,
          name: c.name,
          description: c.description,
          document_count: count(d.id)
        }
      )
    )
  end

  def load_source_ids(repo) do
    import Ecto.Query

    repo.all(
      from(d in Arcana.Document,
        where: not is_nil(d.source_id),
        distinct: d.source_id,
        select: d.source_id
      )
    )
  end

  def get_repo_from_session(session) do
    session["repo"] || Application.get_env(:arcana, :repo) ||
      raise "Missing :arcana, :repo config"
  end

  # CSS styles
  defp css do
    """
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
      text-decoration: none;
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
    .arcana-results-table,
    .arcana-table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.875rem;
    }

    .arcana-documents-table th,
    .arcana-results-table th,
    .arcana-table th {
      text-align: left;
      padding: 0.75rem;
      background: #f3f4f6;
      border-bottom: 2px solid #e5e7eb;
      font-weight: 600;
      color: #374151;
    }

    .arcana-documents-table td,
    .arcana-results-table td,
    .arcana-table td {
      padding: 0.75rem;
      border-bottom: 1px solid #e5e7eb;
      vertical-align: top;
    }

    .arcana-documents-table tr:hover,
    .arcana-results-table tr:hover,
    .arcana-table tr:hover {
      background: #f9fafb;
    }

    .arcana-documents-table code,
    .arcana-results-table code,
    .arcana-table code {
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

    .arcana-filter-bar {
      display: flex;
      align-items: center;
      gap: 0.5rem;
      flex-wrap: wrap;
      padding: 0.75rem 1rem;
      background: #f3f4f6;
      border-radius: 0.5rem;
      margin-bottom: 1rem;
    }

    .arcana-filter-label {
      font-size: 0.875rem;
      font-weight: 500;
      color: #6b7280;
      margin-right: 0.5rem;
    }

    .arcana-filter-btn {
      padding: 0.375rem 0.75rem;
      font-size: 0.875rem;
      border: 1px solid #d1d5db;
      border-radius: 9999px;
      background: white;
      color: #374151;
      cursor: pointer;
      transition: all 0.15s ease;
    }

    .arcana-filter-btn:hover {
      border-color: #7c3aed;
      color: #7c3aed;
    }

    .arcana-filter-btn.active {
      background: #7c3aed;
      border-color: #7c3aed;
      color: white;
    }

    .arcana-filter-clear {
      background: #fef2f2;
      border-color: #fecaca;
      color: #dc2626;
    }

    .arcana-filter-clear:hover {
      background: #fee2e2;
      border-color: #dc2626;
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
      text-decoration: none;
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

    .arcana-btn {
      background: transparent;
      color: #374151;
      border: 1px solid #d1d5db;
      padding: 0.375rem 0.75rem;
      border-radius: 0.25rem;
      font-size: 0.75rem;
      cursor: pointer;
      transition: all 0.15s ease;
    }

    .arcana-btn:hover {
      border-color: #7c3aed;
      color: #7c3aed;
    }

    .arcana-btn-primary {
      background: #7c3aed;
      color: white;
      border-color: #7c3aed;
    }

    .arcana-btn-primary:hover {
      background: #6d28d9;
      border-color: #6d28d9;
      color: white;
    }

    .arcana-btn-danger {
      background: transparent;
      color: #dc2626;
      border-color: #dc2626;
    }

    .arcana-btn-danger:hover {
      background: #dc2626;
      color: white;
    }

    .arcana-form-row {
      display: flex;
      gap: 0.5rem;
      align-items: center;
    }

    .arcana-input {
      padding: 0.5rem;
      border: 1px solid #d1d5db;
      border-radius: 0.375rem;
      font-size: 0.875rem;
    }

    .arcana-input:focus {
      outline: none;
      border-color: #7c3aed;
      box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
    }

    .arcana-confirm-delete {
      display: flex;
      gap: 0.5rem;
      align-items: center;
    }

    .arcana-confirm-delete span {
      font-size: 0.75rem;
      color: #dc2626;
      font-weight: 500;
    }

    /* Evaluation styles */
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

    /* Upload styles */
    .arcana-dropzone {
      border: 2px dashed #d1d5db;
      border-radius: 0.5rem;
      padding: 2rem;
      text-align: center;
      cursor: pointer;
      transition: all 0.15s ease;
      margin-bottom: 1rem;
    }

    .arcana-dropzone:hover {
      border-color: #7c3aed;
      background: #f5f3ff;
    }

    .arcana-dropzone p {
      margin: 0 0 0.5rem 0;
      color: #374151;
    }

    .arcana-upload-hint {
      font-size: 0.75rem;
      color: #6b7280;
    }

    .arcana-file-input {
      display: none;
    }

    .arcana-upload-entry {
      display: flex;
      align-items: center;
      gap: 1rem;
      padding: 0.5rem;
      background: #f9fafb;
      border-radius: 0.375rem;
      margin-bottom: 0.5rem;
    }

    .arcana-upload-entry progress {
      flex: 1;
      height: 0.5rem;
    }

    .arcana-upload-entry button {
      background: transparent;
      border: none;
      color: #dc2626;
      cursor: pointer;
      font-size: 1.25rem;
    }

    .arcana-upload-error {
      color: #dc2626;
      font-size: 0.75rem;
    }

    .arcana-upload-btn {
      background: #7c3aed;
      color: white;
      padding: 0.625rem 1.25rem;
      border: none;
      border-radius: 0.375rem;
      font-size: 0.875rem;
      font-weight: 500;
      cursor: pointer;
    }

    .arcana-upload-btn:hover {
      background: #6d28d9;
    }

    .arcana-divider {
      text-align: center;
      color: #6b7280;
      font-size: 0.875rem;
      margin: 1.5rem 0;
      position: relative;
    }

    .arcana-divider::before,
    .arcana-divider::after {
      content: "";
      position: absolute;
      top: 50%;
      width: 40%;
      height: 1px;
      background: #e5e7eb;
    }

    .arcana-divider::before {
      left: 0;
    }

    .arcana-divider::after {
      right: 0;
    }
    """
  end
end
