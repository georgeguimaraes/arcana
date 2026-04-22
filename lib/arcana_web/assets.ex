defmodule ArcanaWeb.Assets do
  @moduledoc false

  @behaviour Plug

  # Bundle Phoenix LiveView JavaScript at compile time
  @external_resource phoenix_js = Application.app_dir(:phoenix, "priv/static/phoenix.min.js")
  @external_resource phoenix_html_js =
                       Application.app_dir(:phoenix_html, "priv/static/phoenix_html.js")
  @external_resource live_view_js =
                       Application.app_dir(
                         :phoenix_live_view,
                         "priv/static/phoenix_live_view.min.js"
                       )

  @phoenix_js File.read!(phoenix_js)
  @phoenix_html_js File.read!(phoenix_html_js)
  @live_view_js File.read!(live_view_js)

  @app_js """
  // CmdEnterSubmit: when the user presses Cmd+Enter (or Ctrl+Enter on
  // non-mac) inside the bound element (typically a textarea), find the
  // closest form and submit it. Used by the Ask page so the user can
  // submit a question without reaching for the mouse.
  let Hooks = {
    CmdEnterSubmit: {
      mounted() {
        this.handler = (e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault()
            const form = this.el.closest("form")
            if (form) {
              form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
            }
          }
        }
        this.el.addEventListener("keydown", this.handler)
      },
      destroyed() {
        this.el.removeEventListener("keydown", this.handler)
      }
    }
  }

  let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {hooks: Hooks})
  liveSocket.connect()
  window.liveSocket = liveSocket
  """

  @js [@phoenix_js, @phoenix_html_js, @live_view_js, @app_js] |> Enum.join("\n")
  @js_hash :crypto.hash(:md5, @js) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @css """
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
    vertical-align: middle;
  }

  .arcana-documents-table td:nth-child(1) {
    max-width: 120px;
    word-break: break-all;
  }

  .arcana-documents-table td:nth-child(2) {
    max-width: 300px;
  }

  .arcana-documents-table td:nth-child(5),
  .arcana-documents-table td:nth-child(6),
  .arcana-documents-table td:nth-child(7) {
    white-space: nowrap;
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
    align-items: center;
  }

  .arcana-brand {
    font-size: 1.5rem;
    font-weight: 700;
    letter-spacing: -0.025em;
    padding-right: 1.5rem;
    border-right: 1px solid rgba(255, 255, 255, 0.3);
    margin-right: 0.5rem;
    display: flex;
    align-items: center;
    align-self: center;
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
  .arcana-stat-divider {
    width: 1px;
    height: 2rem;
    background: rgba(255, 255, 255, 0.3);
    margin: 0 0.5rem;
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
    /* No background - inherits from page */
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
    border: 1px solid #e5e7eb;
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
    border: 1px solid #e5e7eb;
    padding: 1rem;
    border-radius: 0.5rem;
    font-size: 0.875rem;
    white-space: pre-wrap;
    word-wrap: break-word;
    margin: 0;
    max-height: 300px;
    overflow-y: auto;
  }

  /* Info page grid layout */
  .arcana-info-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
    gap: 1.5rem;
    margin-bottom: 1.5rem;
  }

  .arcana-info-section {
    background: #ffffff;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 1rem;
  }

  .arcana-info-section h3 {
    font-size: 0.875rem;
    font-weight: 600;
    color: #7c3aed;
    margin: 0 0 0.75rem 0;
    padding-bottom: 0.5rem;
    border-bottom: 1px solid #f3e8ff;
  }

  .arcana-info-section .arcana-doc-info {
    margin-bottom: 0;
    background: transparent;
    border: none;
    padding: 0;
  }

  .arcana-info-full {
    grid-column: 1 / -1;
  }

  .arcana-not-configured {
    color: #9ca3af;
  }

  .arcana-status-badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
  }

  .arcana-status-badge.enabled {
    background: #d1fae5;
    color: #065f46;
  }

  .arcana-status-badge.disabled {
    background: #f3f4f6;
    color: #6b7280;
  }

  /* Maintenance page styles */
  .arcana-maintenance-section {
    background: #ffffff;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 1.25rem;
    margin-bottom: 2rem;
  }

  .arcana-maintenance-section h3 {
    font-size: 0.875rem;
    font-weight: 600;
    color: #7c3aed;
    margin: 0 0 0.75rem 0;
    padding-bottom: 0.5rem;
    border-bottom: 1px solid #f3e8ff;
  }

  .arcana-maintenance-section .arcana-doc-info {
    margin-bottom: 0;
    background: transparent;
    border: none;
    padding: 0;
  }

  .arcana-orphan-section {
    background: #fef3c7;
    border-color: #f59e0b;
  }
  .arcana-orphan-section h3 {
    color: #b45309;
    border-bottom-color: #fcd34d;
  }
  .arcana-orphan-count {
    font-weight: 600;
    color: #b45309;
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
    background: #f9fafb;
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
    gap: 1.5rem;
    margin-bottom: 1.5rem;
    border-bottom: 1px solid #e5e7eb;
  }

  .arcana-eval-nav-btn {
    position: relative;
    padding: 0.625rem 0;
    border: none;
    background: transparent;
    font-size: 0.9375rem;
    font-weight: 500;
    color: #6b7280;
    cursor: pointer;
    transition: color 0.15s ease;
    border-bottom: 2px solid transparent;
    margin-bottom: -1px;
  }

  .arcana-eval-nav-btn:hover {
    color: #7c3aed;
  }

  .arcana-eval-nav-btn.active {
    color: #7c3aed;
    border-bottom-color: #7c3aed;
    font-weight: 600;
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

  /* Evaluation run form: vertical stack of sections, radio cards for
     retriever, options row for mode + evaluate_answers toggle, a
     prominent Run Evaluation button bottom-right. Replaces the old
     flex-end one-liner that smushed inputs of different heights next
     to each other. */
  .arcana-eval-run-intro {
    margin: 0 0 1.25rem;
    color: #4b5563;
    font-size: 0.9375rem;
  }

  .arcana-eval-run-intro strong {
    color: #111827;
    font-weight: 600;
  }

  .arcana-eval-run-form {
    display: flex;
    flex-direction: column;
    gap: 1.5rem;
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.75rem;
    padding: 1.5rem;
    margin-bottom: 1.5rem;
  }

  .arcana-eval-field {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .arcana-eval-field-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: #374151;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    margin: 0;
  }

  .arcana-eval-hint {
    font-size: 0.75rem;
    color: #6b7280;
    line-height: 1.4;
  }

  .arcana-eval-option-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 0.75rem;
  }

  .arcana-eval-option-card {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    padding: 1rem 1rem 1rem 1rem;
    background: #fafafa;
    border: 2px solid #e5e7eb;
    border-radius: 0.5rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-eval-option-card input[type="radio"] {
    position: absolute;
    opacity: 0;
    pointer-events: none;
  }

  .arcana-eval-option-card:hover {
    border-color: #c4b5fd;
    background: #faf5ff;
  }

  .arcana-eval-option-card:has(input:checked) {
    border-color: #7c3aed;
    background: #ede9fe;
  }

  .arcana-eval-option-card:has(input:checked) .arcana-eval-option-title {
    color: #6d28d9;
  }

  .arcana-eval-option-title {
    font-size: 0.9375rem;
    font-weight: 600;
    color: #111827;
  }

  .arcana-eval-option-desc {
    font-size: 0.8125rem;
    color: #6b7280;
    line-height: 1.4;
  }

  .arcana-eval-option-desc code {
    font-size: 0.75rem;
    padding: 0.0625rem 0.25rem;
    background: #f3f4f6;
    border-radius: 0.1875rem;
    color: #374151;
  }

  .arcana-eval-options-row {
    display: grid;
    grid-template-columns: minmax(0, 240px) minmax(0, 1fr);
    gap: 1.5rem;
    align-items: start;
  }

  .arcana-eval-select {
    padding: 0.5rem 0.75rem;
    border: 1px solid #d1d5db;
    border-radius: 0.375rem;
    font-size: 0.875rem;
    background: white;
    color: #111827;
  }

  .arcana-eval-toggle {
    position: relative;
    display: flex;
    align-items: flex-start;
    gap: 0.625rem;
    padding: 0.75rem 1rem;
    background: #fafafa;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-eval-toggle input[type="checkbox"] {
    position: absolute;
    opacity: 0;
    pointer-events: none;
  }

  .arcana-eval-toggle-indicator {
    flex-shrink: 0;
    width: 1rem;
    height: 1rem;
    margin-top: 0.125rem;
    border: 2px solid #9ca3af;
    border-radius: 0.25rem;
    background: white;
    transition: all 0.15s ease;
    position: relative;
  }

  .arcana-eval-toggle:has(input:checked) {
    border-color: #7c3aed;
    background: #ede9fe;
  }

  .arcana-eval-toggle:has(input:checked) .arcana-eval-toggle-indicator {
    border-color: #7c3aed;
    background: #7c3aed;
  }

  .arcana-eval-toggle:has(input:checked) .arcana-eval-toggle-indicator::after {
    content: "";
    position: absolute;
    left: 3px;
    top: 0px;
    width: 4px;
    height: 8px;
    border: solid white;
    border-width: 0 2px 2px 0;
    transform: rotate(45deg);
  }

  .arcana-eval-toggle-content {
    display: flex;
    flex-direction: column;
    gap: 0.25rem;
  }

  .arcana-eval-toggle-title {
    font-size: 0.875rem;
    font-weight: 600;
    color: #111827;
  }

  .arcana-eval-actions {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 1rem;
    border-top: 1px solid #f3f4f6;
    padding-top: 1.25rem;
    margin-top: 0.25rem;
  }

  .arcana-eval-progress {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    min-width: 0;
  }

  .arcana-eval-progress-label {
    display: flex;
    justify-content: space-between;
    font-size: 0.8125rem;
    color: #4b5563;
  }

  .arcana-eval-progress-elapsed {
    color: #6b7280;
    font-variant-numeric: tabular-nums;
  }

  .arcana-eval-progress-bar {
    height: 6px;
    background: #ede9fe;
    border-radius: 3px;
    overflow: hidden;
  }

  .arcana-eval-progress-fill {
    height: 100%;
    background: linear-gradient(90deg, #8b5cf6, #7c3aed);
    border-radius: 3px;
    transition: width 0.3s ease;
  }

  .arcana-eval-progress-current {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.8125rem;
    color: #6d28d9;
    margin-top: 0.125rem;
  }

  .arcana-eval-progress-current-label {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  .arcana-eval-progress-spinner {
    display: inline-block;
    width: 0.75rem;
    height: 0.75rem;
    border: 2px solid #ede9fe;
    border-top-color: #7c3aed;
    border-radius: 50%;
    flex-shrink: 0;
    animation: arcana-eval-spin 0.8s linear infinite;
  }

  @keyframes arcana-eval-spin {
    to { transform: rotate(360deg); }
  }

  .arcana-eval-run-btn {
    background: #7c3aed;
    color: white;
    padding: 0.625rem 1.5rem;
    border: none;
    border-radius: 0.5rem;
    font-size: 0.9375rem;
    font-weight: 600;
    cursor: pointer;
    transition: background-color 0.15s ease;
  }

  .arcana-eval-run-btn:hover:not(:disabled) {
    background: #6d28d9;
  }

  .arcana-eval-run-btn:disabled {
    background: #9ca3af;
    cursor: not-allowed;
    opacity: 0.7;
  }

  @media (max-width: 640px) {
    .arcana-eval-option-grid,
    .arcana-eval-options-row {
      grid-template-columns: 1fr;
    }
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

  /* Empty state for the test cases view when no test cases exist. */
  .arcana-eval-empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.5rem;
    padding: 3rem 1rem;
    background: #fafafa;
    border: 1px dashed #d1d5db;
    border-radius: 0.75rem;
    text-align: center;
    color: #6b7280;
  }

  .arcana-eval-empty-state h4 {
    margin: 0;
    font-size: 1rem;
    font-weight: 600;
    color: #374151;
  }

  .arcana-eval-empty-state p {
    margin: 0;
    font-size: 0.875rem;
  }

  .arcana-eval-empty-state code {
    background: #f3f4f6;
    padding: 0.125rem 0.375rem;
    border-radius: 0.25rem;
    font-size: 0.8125rem;
  }

  .arcana-eval-empty-icon {
    font-size: 2.5rem;
    color: #d1d5db;
    line-height: 1;
  }

  /* Test case list: compact rows that expand on click to show the
     reference answer (when present) and the relevant chunks. */
  .arcana-test-case-list {
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
    margin-top: 1.5rem;
  }

  .arcana-test-case {
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    overflow: hidden;
    transition: border-color 0.15s ease;
  }

  .arcana-test-case.expanded {
    border-color: #c4b5fd;
  }

  .arcana-test-case-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 0.625rem 0.875rem;
  }

  .arcana-test-case-row-main {
    display: grid;
    grid-template-columns: auto 1fr auto auto auto;
    align-items: center;
    gap: 0.75rem;
    flex: 1;
    min-width: 0;
    cursor: pointer;
    padding: 0.125rem 0;
    border-radius: 0.25rem;
    transition: background-color 0.15s ease;
  }

  .arcana-test-case-row-main:hover {
    background: #fafafa;
  }

  .arcana-test-case.expanded .arcana-test-case-row {
    background: #faf5ff;
    border-bottom: 1px solid #ede9fe;
  }

  .arcana-test-case-chevron {
    color: #9ca3af;
    font-size: 0.75rem;
    width: 0.75rem;
    text-align: center;
  }

  .arcana-test-case-question {
    font-size: 0.875rem;
    color: #111827;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    min-width: 0;
  }

  .arcana-test-case-badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.02em;
  }

  .arcana-test-case-badge--generated {
    background: #ede9fe;
    color: #6d28d9;
  }

  .arcana-test-case-badge--synthetic {
    background: #ede9fe;
    color: #6d28d9;
  }

  .arcana-test-case-badge--manual {
    background: #dbeafe;
    color: #1d4ed8;
  }

  .arcana-test-case-chunks {
    font-size: 0.75rem;
    color: #6b7280;
    white-space: nowrap;
    font-variant-numeric: tabular-nums;
  }

  .arcana-test-case-time {
    font-size: 0.75rem;
    color: #9ca3af;
    white-space: nowrap;
    cursor: help;
  }

  .arcana-test-case-detail {
    padding: 1rem 1rem 1.25rem 2rem;
    background: #fafafa;
  }

  .arcana-test-case-detail-section {
    margin-top: 0.75rem;
  }

  .arcana-test-case-detail-section:first-child {
    margin-top: 0;
  }

  .arcana-test-case-detail-section h5 {
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #6d28d9;
    margin: 0 0 0.375rem;
  }

  .arcana-test-case-detail-section p {
    margin: 0;
    font-size: 0.875rem;
    color: #374151;
    line-height: 1.5;
  }

  .arcana-test-case-chunk-list {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 0.375rem;
  }

  .arcana-test-case-chunk-list li {
    display: grid;
    grid-template-columns: auto 1fr;
    gap: 0.625rem;
    align-items: baseline;
    padding: 0.375rem 0.5rem;
    background: white;
    border-radius: 0.25rem;
    border: 1px solid #f3f4f6;
  }

  .arcana-test-case-chunk-id {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.75rem;
    color: #7c3aed;
    padding: 0.0625rem 0.25rem;
    background: #faf5ff;
    border-radius: 0.1875rem;
  }

  .arcana-test-case-chunk-text {
    font-size: 0.8125rem;
    color: #4b5563;
    line-height: 1.5;
  }

  .arcana-test-case-empty {
    font-size: 0.875rem;
    color: #9ca3af;
    font-style: italic;
  }

  .arcana-actions-cell {
    text-align: center;
    white-space: nowrap;
  }

  .arcana-icon-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0.375rem;
    background: transparent;
    color: #9ca3af;
    border: none;
    border-radius: 0.25rem;
    cursor: pointer;
  }

  .arcana-icon-btn:hover {
    color: #7c3aed;
    background: #f3f4f6;
  }

  .arcana-delete-btn {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 0.375rem;
    background: transparent;
    color: #9ca3af;
    border: none;
    border-radius: 0.25rem;
    cursor: pointer;
  }

  .arcana-delete-btn:hover {
    color: #dc2626;
    background: #fef2f2;
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
    position: relative;
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
    position: absolute;
    inset: 0;
    opacity: 0;
    cursor: pointer;
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

  /* Search Results Styles */
  .arcana-search-results {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .arcana-search-result {
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    overflow: hidden;
    background: white;
  }

  .arcana-result-header {
    display: flex;
    align-items: center;
    gap: 1rem;
    padding: 0.75rem 1rem;
    background: #f9fafb;
    border-bottom: 1px solid #e5e7eb;
  }

  .arcana-result-score {
    min-width: 60px;
  }

  .arcana-result-score .score-value {
    font-weight: 600;
    color: #7c3aed;
    font-size: 0.875rem;
  }

  .arcana-result-meta {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex: 1;
  }

  .arcana-result-meta code {
    font-size: 0.7rem;
  }

  .arcana-chunk-badge {
    background: #ede9fe;
    color: #6d28d9;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
  }

  .arcana-result-actions {
    display: flex;
    gap: 0.5rem;
  }

  .arcana-result-btn {
    padding: 0.375rem 0.75rem;
    border: 1px solid #d1d5db;
    border-radius: 0.375rem;
    background: white;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-result-btn:hover {
    border-color: #7c3aed;
    color: #7c3aed;
  }

  .arcana-result-btn-primary {
    background: #7c3aed;
    border-color: #7c3aed;
    color: white;
  }

  .arcana-result-btn-primary:hover {
    background: #6d28d9;
    border-color: #6d28d9;
    color: white;
  }

  .arcana-result-text {
    padding: 1rem;
    font-size: 0.875rem;
    white-space: pre-wrap;
    word-wrap: break-word;
    color: #374151;
    max-height: 100px;
    overflow: hidden;
    position: relative;
  }

  .arcana-result-text.expanded {
    max-height: none;
    overflow: visible;
  }

  /* ChunkResultsComponent: grouped chunks with expandable details. */
  .arcana-chunk-results {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .arcana-chunk-doc {
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    overflow: hidden;
  }

  .arcana-chunk-doc--has-source {
    border-color: #a7f3d0;
    box-shadow: 0 0 0 1px #a7f3d0 inset;
  }

  .arcana-chunk-doc-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    padding: 0.625rem 0.875rem;
    background: #f9fafb;
    border-bottom: 1px solid #e5e7eb;
  }

  .arcana-chunk-doc--has-source .arcana-chunk-doc-header {
    background: #ecfdf5;
    border-bottom-color: #a7f3d0;
  }

  .arcana-chunk-doc-title {
    margin: 0;
    font-size: 0.875rem;
    font-weight: 600;
    color: #111827;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
    min-width: 0;
  }

  .arcana-chunk-doc-link {
    color: inherit;
    text-decoration: none;
    transition: color 0.15s ease;
  }

  .arcana-chunk-doc-link:hover {
    color: #6d28d9;
    text-decoration: underline;
  }

  .arcana-chunk-doc-meta {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    font-size: 0.75rem;
    color: #6b7280;
    flex-shrink: 0;
  }

  .arcana-chunk-source-dot {
    display: inline-block;
    width: 0.5rem;
    height: 0.5rem;
    border-radius: 50%;
    background: #10b981;
  }

  .arcana-chunk-list {
    list-style: none;
    margin: 0;
    padding: 0;
  }

  .arcana-chunk-item {
    border-top: 1px solid #f3f4f6;
  }

  .arcana-chunk-item:first-child {
    border-top: none;
  }

  .arcana-chunk-item--source {
    background: #f0fdf4;
  }

  .arcana-chunk-details {
    width: 100%;
  }

  .arcana-chunk-summary {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    padding: 0.5rem 0.875rem;
    cursor: pointer;
    list-style: none;
    font-size: 0.8125rem;
    line-height: 1.4;
    user-select: none;
  }

  .arcana-chunk-summary::-webkit-details-marker {
    display: none;
  }

  .arcana-chunk-summary::before {
    content: '▸';
    color: #9ca3af;
    font-size: 0.6875rem;
    flex-shrink: 0;
    transition: transform 0.15s ease;
    display: inline-block;
  }

  .arcana-chunk-details[open] > .arcana-chunk-summary::before {
    transform: rotate(90deg);
  }

  .arcana-chunk-summary:hover {
    background: #f9fafb;
  }

  .arcana-chunk-item--source .arcana-chunk-summary:hover {
    background: #dcfce7;
  }

  .arcana-chunk-score {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.6875rem;
    font-weight: 600;
    color: #6d28d9;
    flex-shrink: 0;
  }

  .arcana-chunk-index {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.6875rem;
    color: #9ca3af;
    flex-shrink: 0;
  }

  .arcana-chunk-supports {
    font-size: 0.6875rem;
    font-weight: 600;
    color: #047857;
    background: #d1fae5;
    padding: 0.125rem 0.375rem;
    border-radius: 0.25rem;
    flex-shrink: 0;
  }

  .arcana-chunk-via {
    font-size: 0.6875rem;
    color: #7c3aed;
    background: #ede9fe;
    padding: 0.125rem 0.375rem;
    border-radius: 0.25rem;
    flex-shrink: 0;
    max-width: 12rem;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .arcana-chunk-preview {
    flex: 1;
    min-width: 0;
    color: #4b5563;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .arcana-chunk-full {
    padding: 0.75rem 1rem 1rem 2.25rem;
    font-size: 0.8125rem;
    line-height: 1.55;
    color: #1f2937;
    white-space: pre-line;
    border-top: 1px dashed #e5e7eb;
  }

  /* Collection checkboxes - shared between Search and Ask tabs */
  .arcana-ask-collections {
    margin: 1rem 0;
  }

  .arcana-ask-collections > label {
    display: block;
    font-size: 0.875rem;
    font-weight: 500;
    color: #374151;
    margin-bottom: 0.5rem;
  }

  .arcana-llm-select-toggle {
    margin-bottom: 0.75rem;
    padding: 0.75rem;
    background: #f5f3ff;
    border: 1px solid #ddd6fe;
    border-radius: 0.5rem;
  }
  .arcana-llm-select-toggle .arcana-checkbox-label {
    margin: 0;
  }

  .arcana-collection-checkboxes {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
  }

  .arcana-collection-check {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    padding: 0.375rem 0.75rem;
    background: white;
    border: 1px solid #d1d5db;
    border-radius: 0.375rem;
    font-size: 0.8125rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-collection-check:hover {
    border-color: #7c3aed;
    background: #faf5ff;
  }

  .arcana-collection-check:has(input:checked) {
    border-color: #7c3aed;
    background: #ede9fe;
    color: #5b21b6;
  }

  .arcana-collection-check input {
    accent-color: #7c3aed;
  }

  .arcana-collection-hint {
    display: block;
    margin-top: 0.375rem;
    font-size: 0.75rem;
    color: #6b7280;
  }

  /* Tab description */
  .arcana-tab-description {
    color: #6b7280;
    margin-bottom: 1rem;
    font-size: 0.875rem;
  }

  /* Ask tab styles */
  .arcana-ask-mode-nav {
    display: inline-flex;
    background: #f3f4f6;
    border-radius: 0.5rem;
    padding: 0.25rem;
    margin-bottom: 0.75rem;
  }

  .arcana-mode-btn {
    padding: 0.5rem 1rem;
    border: none;
    background: transparent;
    color: #6b7280;
    font-size: 0.875rem;
    font-weight: 500;
    border-radius: 0.375rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-mode-btn:hover {
    color: #374151;
  }

  .arcana-mode-btn.active {
    background: white;
    color: #7c3aed;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
  }

  .arcana-mode-description {
    color: #9ca3af;
    font-size: 0.8125rem;
    margin-bottom: 1rem;
    font-style: italic;
  }

  .arcana-ask-form {
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 1rem;
    margin-bottom: 1.5rem;
  }

  .arcana-ask-input textarea {
    width: 100%;
    padding: 0.75rem;
    border: 1px solid #d1d5db;
    border-radius: 0.375rem;
    font-size: 0.875rem;
    resize: vertical;
    box-sizing: border-box;
  }

  .arcana-ask-input textarea:focus {
    outline: none;
    border-color: #7c3aed;
    box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
  }

  .arcana-ask-options {
    margin-top: 1rem;
    padding-top: 1rem;
    border-top: 1px solid #e5e7eb;
  }

  .arcana-ask-options h4 {
    font-size: 0.875rem;
    font-weight: 600;
    color: #374151;
    margin: 0 0 0.75rem 0;
  }

  .arcana-pipeline {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .arcana-pipeline > li {
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  .arcana-pipeline > li:not(:last-child)::after {
    content: '';
    display: block;
    width: 2px;
    height: 1.25rem;
    background: #c4b5fd;
  }

  .arcana-pipeline > li:has(> .arcana-pipeline-step:not(:has(input:checked)):not(.fixed)):not(:last-child)::after {
    background: none;
    border-left: 2px dashed #d1d5db;
  }

  .arcana-pipeline-step {
    display: flex;
    flex-direction: column;
    align-items: center;
    width: 240px;
    padding: 0.625rem 1rem;
    background: #fafafa;
    border: 2px dashed #d1d5db;
    border-radius: 0.5rem;
    cursor: pointer;
    transition: all 0.15s ease;
    text-align: center;
  }

  .arcana-pipeline-step:has(input:checked) {
    background: #ede9fe;
    border: 2px solid #7c3aed;
  }

  .arcana-pipeline-step:has(input:checked) .arcana-step-label {
    color: #6d28d9;
  }

  .arcana-pipeline-step:not(.fixed):hover {
    border-color: #a78bfa;
  }

  .arcana-pipeline-step.fixed {
    background: #f0fdf4;
    border: 2px solid #86efac;
    cursor: default;
  }

  .arcana-pipeline-step.fixed .arcana-step-label {
    color: #15803d;
  }

  .arcana-pipeline-step input[type="checkbox"],
  .arcana-pipeline-step input[type="radio"] {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
  }

  .arcana-step-label {
    font-size: 0.875rem;
    font-weight: 600;
    color: #374151;
  }

  .arcana-pipeline-step small {
    font-size: 0.75rem;
    color: #6b7280;
    margin-top: 0.125rem;
  }

  .arcana-pipeline-fork {
    display: flex;
    align-items: center;
    gap: 0.75rem;
  }

  .arcana-pipeline-fork .arcana-pipeline-step {
    width: 160px;
  }

  .arcana-fork-or {
    font-size: 0.75rem;
    font-weight: 500;
    color: #9ca3af;
    text-transform: uppercase;
  }

  .arcana-pipeline-step:has(input:disabled) {
    opacity: 0.5;
    cursor: not-allowed;
  }

  /* Phase grouping: wraps the flat pipeline into three labeled sections
     (Query preparation, Retrieval, Answer) with a thin divider line
     between them. Each phase keeps its own vertical flow; the dividers
     make the three stages visible without losing the single-column shape. */
  .arcana-pipeline-phases {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 1rem;
  }

  .arcana-pipeline-phase {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 1rem 0.75rem 1.25rem;
    background: #faf5ff;
    border: 1px solid #ede9fe;
    border-radius: 0.625rem;
  }

  .arcana-pipeline-phase-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    width: 100%;
    max-width: 280px;
    margin: 0 auto 0.75rem;
  }

  .arcana-pipeline-phase-header h5 {
    margin: 0;
    font-size: 0.6875rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: #7c3aed;
  }

  .arcana-pipeline-phase-toggle {
    font-size: 0.6875rem;
    font-weight: 400;
    color: #9ca3af;
    letter-spacing: 0;
    text-transform: none;
  }

  /* Substep: a conditional loop on the previous step (Multi-hop reasoning
     loops search, Self-correction loops answer). The ↻ glyph on the label
     signals the loop relationship. Keeps the same width + center axis as
     the primary steps so the vertical connector stays straight. */
  .arcana-loop-glyph {
    display: inline-block;
    margin-right: 0.25rem;
    color: #a78bfa;
    font-weight: 700;
  }

  .arcana-pipeline-step:has(input:checked) .arcana-loop-glyph {
    color: #7c3aed;
  }

  /* Ask page sub-tabs: segmented pill control. Distinct from the
     top-level .arcana-tab nav (which uses underlines) so the two
     navigation levels don't visually compete. */
  .arcana-ask-sub-tab-nav {
    display: inline-flex;
    align-items: center;
    background: #f3f4f6;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 0.25rem;
    gap: 0.125rem;
    margin: 1rem 0 0.75rem;
  }

  .arcana-ask-sub-tab {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-height: 36px;
    padding: 0.5rem 1.25rem;
    border: none;
    background: transparent;
    font-size: 0.875rem;
    font-weight: 500;
    color: #6b7280;
    cursor: pointer;
    border-radius: 0.375rem;
    transition: all 0.15s ease;
  }

  .arcana-ask-sub-tab:hover:not(.active) {
    color: #4b5563;
    background: rgba(255, 255, 255, 0.6);
  }

  .arcana-ask-sub-tab.active {
    background: #ffffff;
    color: #6d28d9;
    font-weight: 600;
    box-shadow:
      0 1px 2px rgba(15, 23, 42, 0.06),
      0 1px 3px rgba(15, 23, 42, 0.04);
  }

  .arcana-sub-tab-description {
    color: #6b7280;
    font-size: 0.875rem;
    margin: 0 0 1.25rem 0;
    line-height: 1.5;
  }

  /* Loop settings: card grid that mirrors the .arcana-pipeline-step
     visual language so the Loop sub-tab feels like part of the same
     surface as the Pipeline sub-tab. */
  .arcana-loop-settings {
    margin-top: 0.75rem;
  }

  .arcana-loop-settings h4 {
    font-size: 0.6875rem;
    font-weight: 600;
    color: #6b7280;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin: 0 0 0.5rem 0;
  }

  /* Two-row layout: info cards (4-col) row, then number+toggle (2-col)
     row. Both rows live inside the same grid so column widths align.
     Info cards are horizontally compact; number inputs and the toggle
     get their own tighter row beneath them. */
  .arcana-loop-settings-grid {
    display: grid;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    gap: 0.5rem;
  }

  .arcana-loop-setting {
    display: flex;
    flex-direction: column;
    padding: 0.625rem 0.75rem;
    background: #fafafa;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    gap: 0.125rem;
    transition: border-color 0.15s ease;
    min-width: 0;
  }

  .arcana-loop-setting:hover {
    border-color: #d1d5db;
  }

  .arcana-loop-setting label {
    font-size: 0.75rem;
    font-weight: 600;
    color: #374151;
  }

  .arcana-loop-setting > small {
    font-size: 0.6875rem;
    color: #6b7280;
    line-height: 1.35;
  }

  .arcana-loop-setting code {
    font-size: 0.625rem;
    background: #ede9fe;
    color: #6d28d9;
    padding: 0.0625rem 0.3125rem;
    border-radius: 0.1875rem;
  }

  .arcana-loop-setting--info {
    background: #f5f3ff;
    border-color: #ddd6fe;
  }

  .arcana-loop-setting--info:hover {
    border-color: #c4b5fd;
  }

  .arcana-loop-setting-value {
    margin-top: 0.25rem;
    font-size: 0.6875rem;
    color: #6d28d9;
    font-family:
      ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Inline temperature row inside an LLM info card. The temperature is
     visually attached to the LLM it controls so users can see at a
     glance which model each setting affects. */
  .arcana-loop-setting-temp {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    margin-top: 0.5rem;
    padding-top: 0.5rem;
    border-top: 1px dashed #ddd6fe;
  }

  .arcana-loop-setting-temp label {
    font-size: 0.625rem;
    font-weight: 600;
    color: #9ca3af;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    margin: 0;
  }

  .arcana-loop-setting-temp input[type="number"] {
    width: 2.75rem;
    margin: 0;
    padding: 0.125rem 0.3125rem;
    border: 1px solid #ddd6fe;
    border-radius: 0.25rem;
    font-size: 0.6875rem;
    background: white;
    color: #6d28d9;
    box-sizing: border-box;
    /* Hide the spin buttons in WebKit since the field is too narrow
       for them to be useful and they consume horizontal space. */
    appearance: textfield;
    -moz-appearance: textfield;
  }

  .arcana-loop-setting-temp input[type="number"]::-webkit-inner-spin-button,
  .arcana-loop-setting-temp input[type="number"]::-webkit-outer-spin-button {
    -webkit-appearance: none;
    margin: 0;
  }

  .arcana-loop-setting-temp input[type="number"]:focus {
    outline: none;
    border-color: #7c3aed;
    box-shadow: 0 0 0 2px rgba(124, 58, 237, 0.15);
  }

  .arcana-loop-setting-temp input[type="number"]:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  /* Number-input cards (max_iterations, chunk_cap) sit in two
     compact columns beneath the four LLM info cards. The remaining
     two columns of the row are visually balanced by the full-width
     toggle below. */
  .arcana-loop-setting--number {
    grid-column: span 1;
  }

  .arcana-loop-setting input[type="number"] {
    margin-top: 0.25rem;
    width: 100%;
    padding: 0.375rem 0.625rem;
    border: 1px solid #d1d5db;
    border-radius: 0.3125rem;
    font-size: 0.8125rem;
    background: white;
    color: #111827;
    box-sizing: border-box;
    transition:
      border-color 0.15s ease,
      box-shadow 0.15s ease;
  }

  .arcana-loop-setting input[type="number"]:focus {
    outline: none;
    border-color: #7c3aed;
    box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
  }

  .arcana-loop-setting input[type="number"]:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .arcana-loop-setting--toggle {
    grid-column: 1 / -1;
    flex-direction: row;
    align-items: center;
    gap: 0.625rem;
    padding: 0.5rem 0.75rem;
    cursor: pointer;
  }

  .arcana-loop-setting--toggle:has(input:checked) {
    background: #ede9fe;
    border-color: #7c3aed;
  }

  .arcana-loop-setting--toggle:has(input:checked) .arcana-loop-toggle-label {
    color: #6d28d9;
  }

  .arcana-loop-setting--toggle input[type="checkbox"] {
    margin: 0;
    width: 15px;
    height: 15px;
    accent-color: #7c3aed;
    cursor: pointer;
    flex-shrink: 0;
  }

  .arcana-loop-toggle-content {
    display: flex;
    flex-direction: row;
    align-items: baseline;
    gap: 0.5rem;
    flex-wrap: wrap;
    min-width: 0;
  }

  .arcana-loop-toggle-label {
    font-size: 0.75rem;
    font-weight: 600;
    color: #374151;
  }

  .arcana-loop-toggle-content small {
    font-size: 0.6875rem;
    color: #6b7280;
    line-height: 1.3;
  }

  /* Loop trace: shared visual language for both the live (during run)
     and the static (post run) tool history. The live variant adds a
     pulsing header and a slide-in animation on each new entry. */
  .arcana-loop-trace,
  .arcana-loop-live-trace {
    margin-top: 1rem;
    background: #fafafa;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 1rem 1.25rem;
  }

  .arcana-loop-live-trace {
    background: linear-gradient(180deg, #faf5ff 0%, #fafafa 100%);
    border-color: #ddd6fe;
  }

  .arcana-loop-trace h4 {
    font-size: 0.75rem;
    font-weight: 600;
    color: #6b7280;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin: 0 0 0.875rem 0;
    display: flex;
    align-items: center;
    gap: 0.625rem;
  }

  .arcana-loop-meta {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #9ca3af;
    text-transform: none;
    letter-spacing: 0;
  }

  .arcana-loop-meta code {
    font-size: 0.6875rem;
    background: #ede9fe;
    color: #6d28d9;
    padding: 0.0625rem 0.375rem;
    border-radius: 0.25rem;
  }

  .arcana-loop-live-header {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    font-size: 0.75rem;
    font-weight: 600;
    color: #6d28d9;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    margin-bottom: 0.875rem;
  }

  .arcana-loop-live-pulse {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #7c3aed;
    box-shadow: 0 0 0 0 rgba(124, 58, 237, 0.6);
    animation: arcana-loop-pulse 1.6s ease-out infinite;
  }

  @keyframes arcana-loop-pulse {
    0% {
      box-shadow: 0 0 0 0 rgba(124, 58, 237, 0.6);
    }
    70% {
      box-shadow: 0 0 0 8px rgba(124, 58, 237, 0);
    }
    100% {
      box-shadow: 0 0 0 0 rgba(124, 58, 237, 0);
    }
  }

  .arcana-loop-live-title {
    flex: 1;
  }

  .arcana-loop-live-count {
    font-size: 0.6875rem;
    font-weight: 500;
    color: #9ca3af;
    text-transform: none;
    letter-spacing: 0;
  }

  .arcana-loop-live-empty {
    font-size: 0.8125rem;
    color: #9ca3af;
    font-style: italic;
    padding: 0.5rem 0 0.25rem;
  }

  .arcana-loop-iterations {
    list-style: none;
    margin: 0;
    padding: 0;
    position: relative;
  }

  /* Vertical timeline rail running down the left side of the iteration
     list. Anchored to the iter-num badge so the rail aligns with the
     center of each badge. */
  .arcana-loop-iterations::before {
    content: '';
    position: absolute;
    left: 0.875rem;
    top: 0.75rem;
    bottom: 0.75rem;
    width: 2px;
    background: #e5e7eb;
    border-radius: 1px;
  }

  .arcana-loop-iterations--live::before {
    background: linear-gradient(180deg, #c4b5fd 0%, #ddd6fe 100%);
  }

  .arcana-loop-iteration {
    position: relative;
    padding: 0.375rem 0 0.375rem 2.25rem;
    min-height: 2.5rem;
    display: flex;
    align-items: center;
    animation: arcana-loop-fade-in 0.35s ease-out both;
  }

  @keyframes arcana-loop-fade-in {
    from {
      opacity: 0;
      transform: translateY(-4px);
    }
    to {
      opacity: 1;
      transform: translateY(0);
    }
  }

  .arcana-loop-iter-header {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    flex-wrap: wrap;
    min-height: 1.75rem;
  }

  .arcana-loop-iter-num {
    position: absolute;
    left: 0;
    top: 50%;
    transform: translateY(-50%);
    width: 1.75rem;
    height: 1.75rem;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: white;
    border: 2px solid #e5e7eb;
    border-radius: 50%;
    font-size: 0.6875rem;
    font-weight: 700;
    color: #6b7280;
    z-index: 1;
  }

  .arcana-loop-iterations--live .arcana-loop-iter-num {
    border-color: #c4b5fd;
    color: #6d28d9;
  }

  /* Per-tool color coding so search vs answer vs give_up is scannable */
  .arcana-tool-search .arcana-loop-iter-num {
    border-color: #93c5fd;
    color: #1d4ed8;
    background: #eff6ff;
  }

  .arcana-tool-answer .arcana-loop-iter-num {
    border-color: #86efac;
    color: #15803d;
    background: #f0fdf4;
  }

  .arcana-tool-give_up .arcana-loop-iter-num {
    border-color: #fca5a5;
    color: #b91c1c;
    background: #fef2f2;
  }

  .arcana-tool-synthesis .arcana-loop-iter-num {
    border-color: #fcd34d;
    color: #b45309;
    background: #fffbeb;
  }

  .arcana-loop-tool {
    font-size: 0.8125rem;
    font-weight: 600;
    font-family:
      ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    padding: 0.125rem 0.5rem;
    border-radius: 0.25rem;
    background: #f3f4f6;
    color: #374151;
  }

  .arcana-tool-search .arcana-loop-tool {
    background: #dbeafe;
    color: #1d4ed8;
  }

  .arcana-tool-answer .arcana-loop-tool {
    background: #dcfce7;
    color: #15803d;
  }

  .arcana-tool-give_up .arcana-loop-tool {
    background: #fee2e2;
    color: #b91c1c;
  }

  .arcana-tool-synthesis .arcana-loop-tool {
    background: #fef3c7;
    color: #b45309;
  }

  /* Pipeline step trace: same visual language as the loop trace, but
     each entry is a "step" with a running/done state instead of a
     completed tool call. The number badge contains a tiny spinner
     while running, then becomes a step number when done. */
  .arcana-pipeline-iterations::before {
    background: linear-gradient(180deg, #c4b5fd 0%, #ddd6fe 100%);
  }

  .arcana-pipeline-step-trace--running .arcana-loop-iter-num {
    background: #f5f3ff;
    border-color: #c4b5fd;
    color: #6d28d9;
  }

  .arcana-pipeline-step-trace--running .arcana-loop-tool {
    background: #ede9fe;
    color: #6d28d9;
  }

  .arcana-pipeline-step-trace--done .arcana-loop-iter-num {
    background: #f0fdf4;
    border-color: #86efac;
    color: #15803d;
  }

  .arcana-pipeline-step-trace--done .arcana-loop-tool {
    background: #dcfce7;
    color: #15803d;
  }

  .arcana-pipeline-step-spinner {
    width: 0.75rem;
    height: 0.75rem;
    border-radius: 50%;
    border: 2px solid rgba(124, 58, 237, 0.25);
    border-top-color: #7c3aed;
    animation: arcana-pipeline-spin 0.8s linear infinite;
  }

  @keyframes arcana-pipeline-spin {
    to {
      transform: rotate(360deg);
    }
  }

  .arcana-loop-args {
    font-size: 0.8125rem;
    color: #4b5563;
    font-family:
      ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
    flex: 1;
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .arcana-loop-chunk-count {
    font-size: 0.6875rem;
    font-weight: 600;
    color: #6d28d9;
    background: #ede9fe;
    padding: 0.125rem 0.5rem;
    border-radius: 999px;
    flex-shrink: 0;
  }

  .arcana-checkbox-label {
    display: flex;
    flex-direction: column;
    padding: 0.75rem;
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-checkbox-label:hover {
    border-color: #7c3aed;
  }

  .arcana-checkbox-label input[type="checkbox"] {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
  }

  .arcana-checkbox-label span {
    font-size: 0.875rem;
    font-weight: 500;
    color: #374151;
  }

  .arcana-checkbox-label small {
    font-size: 0.75rem;
    color: #6b7280;
    margin-top: 0.25rem;
  }

  .arcana-checkbox-label:has(input:checked) {
    background: #ede9fe;
    border-color: #7c3aed;
  }

  .arcana-checkbox-label:has(input:checked) span {
    color: #6d28d9;
  }

  .arcana-checkbox-label:has(input:disabled) {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .arcana-ask-actions {
    display: flex;
    gap: 0.5rem;
    margin-top: 1rem;
  }

  .arcana-ask-actions button {
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

  .arcana-ask-actions button:hover {
    background: #6d28d9;
  }

  .arcana-ask-actions button:disabled {
    background: #9ca3af;
    cursor: not-allowed;
  }

  .arcana-ask-actions button[type="button"] {
    background: transparent;
    color: #6b7280;
    border: 1px solid #d1d5db;
  }

  .arcana-ask-actions button[type="button"]:hover {
    border-color: #7c3aed;
    color: #7c3aed;
    background: transparent;
  }

  .arcana-ask-loading {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    padding: 1.5rem;
    background: #f9fafb;
    border-radius: 0.5rem;
    color: #6b7280;
  }

  .arcana-spinner {
    width: 1.25rem;
    height: 1.25rem;
    border: 2px solid #e5e7eb;
    border-top-color: #7c3aed;
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .arcana-ask-results {
    margin-top: 1.5rem;
  }

  .arcana-ask-answer {
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    overflow: hidden;
    margin-bottom: 1rem;
  }

  .arcana-ask-answer h3 {
    margin: 0;
    padding: 0.75rem 1rem;
    background: linear-gradient(135deg, #7c3aed 0%, #6d28d9 100%);
    color: white;
    font-size: 0.875rem;
    font-weight: 600;
  }

  .arcana-answer-content {
    padding: 1rem 1.25rem;
    font-size: 0.875rem;
    line-height: 1.6;
    color: #1f2937;
  }

  /* Markdown elements inside a rendered answer. Earmark produces
     standard HTML, so we style a minimal set: paragraphs, lists,
     inline emphasis, inline code, and a few headers. */
  .arcana-answer-content > :first-child {
    margin-top: 0;
  }

  .arcana-answer-content > :last-child {
    margin-bottom: 0;
  }

  .arcana-answer-content p {
    margin: 0 0 0.75rem 0;
  }

  .arcana-answer-content ul,
  .arcana-answer-content ol {
    margin: 0 0 0.75rem 0;
    padding-left: 1.5rem;
  }

  .arcana-answer-content li {
    margin-bottom: 0.25rem;
  }

  .arcana-answer-content li > ul,
  .arcana-answer-content li > ol {
    margin-top: 0.25rem;
    margin-bottom: 0.25rem;
  }

  .arcana-answer-content strong {
    font-weight: 600;
    color: #111827;
  }

  .arcana-answer-content em {
    font-style: italic;
  }

  .arcana-answer-content code {
    background: #f3f4f6;
    color: #7c3aed;
    padding: 0.0625rem 0.375rem;
    border-radius: 0.25rem;
    font-size: 0.8125rem;
    font-family:
      ui-monospace, "SF Mono", Menlo, Monaco, Consolas, "Liberation Mono", monospace;
  }

  .arcana-answer-content pre {
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    padding: 0.75rem;
    overflow-x: auto;
    margin: 0 0 0.75rem 0;
  }

  .arcana-answer-content pre code {
    background: transparent;
    color: inherit;
    padding: 0;
  }

  .arcana-answer-content h1,
  .arcana-answer-content h2,
  .arcana-answer-content h3,
  .arcana-answer-content h4,
  .arcana-answer-content h5,
  .arcana-answer-content h6 {
    font-weight: 700;
    color: #1f2937;
    margin: 1.5rem 0 0.5rem 0;
    line-height: 1.3;
  }

  /* First heading shouldn't push down — there's already padding above. */
  .arcana-answer-content > :first-child:is(h1, h2, h3, h4, h5, h6) {
    margin-top: 0;
  }

  .arcana-answer-content h1 {
    font-size: 1.25rem;
    color: #111827;
    padding-bottom: 0.375rem;
    border-bottom: 2px solid #ede9fe;
  }

  /* h2 is the most common section heading the LLM emits. Distinctive
     but not loud: a left accent bar + a slightly bigger size + a touch
     of color. */
  .arcana-answer-content h2 {
    font-size: 1.0625rem;
    color: #6d28d9;
    padding-left: 0.75rem;
    border-left: 3px solid #7c3aed;
  }

  .arcana-answer-content h3 {
    font-size: 0.9375rem;
    color: #4b5563;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-weight: 600;
  }

  .arcana-answer-content h4,
  .arcana-answer-content h5,
  .arcana-answer-content h6 {
    font-size: 0.875rem;
    color: #4b5563;
    font-weight: 600;
  }

  .arcana-answer-content blockquote {
    border-left: 3px solid #c4b5fd;
    padding-left: 0.875rem;
    color: #4b5563;
    margin: 0 0 0.75rem 0;
  }

  .arcana-answer-content a {
    color: #7c3aed;
    text-decoration: underline;
  }

  .arcana-answer-content a:hover {
    color: #6d28d9;
  }

  .arcana-ask-section {
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 1rem;
    margin-bottom: 1rem;
  }

  .arcana-ask-section h4 {
    margin: 0 0 0.75rem 0;
    font-size: 0.875rem;
    font-weight: 600;
    color: #374151;
  }

  .arcana-query-list {
    margin: 0;
    padding-left: 1.5rem;
    font-size: 0.875rem;
    color: #374151;
  }

  .arcana-query-list li {
    margin-bottom: 0.25rem;
  }

  /* Pipeline internals: one block below the answer that shows what each
     pipeline step produced (rewritten query, gate decision, sub-questions,
     etc). Renders as a <dl> with each step's label + value on one line. */
  .arcana-pipeline-internals-list {
    display: grid;
    grid-template-columns: max-content 1fr;
    gap: 0.5rem 1rem;
    margin: 0;
    font-size: 0.875rem;
  }

  .arcana-pipeline-internals-list dt {
    font-weight: 600;
    color: #6d28d9;
    white-space: nowrap;
  }

  .arcana-pipeline-internals-list dd {
    margin: 0;
    color: #374151;
    min-width: 0;
  }

  .arcana-pipeline-internals-quote {
    font-family: ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace;
    font-size: 0.8125rem;
    color: #4b5563;
    background: #f9fafb;
    padding: 0.125rem 0.5rem;
    border-radius: 0.25rem;
    display: inline-block;
  }

  .arcana-pipeline-internals-badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 600;
  }

  .arcana-pipeline-internals-badge.skip {
    background: #fef3c7;
    color: #b45309;
  }

  .arcana-pipeline-internals-badge.retrieve {
    background: #dbeafe;
    color: #1d4ed8;
  }

  .arcana-pipeline-internals-badge.neutral {
    background: #f3f4f6;
    color: #6b7280;
  }

  .arcana-pipeline-internals-reasoning {
    display: block;
    margin-top: 0.25rem;
    font-size: 0.8125rem;
    color: #6b7280;
    font-style: italic;
  }

  .arcana-pipeline-internals-feedback {
    font-size: 0.8125rem;
    color: #6b7280;
    font-style: italic;
    margin-bottom: 0.25rem;
  }

  .arcana-collection-badges {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .arcana-collection-badge {
    background: #ede9fe;
    color: #6d28d9;
    padding: 0.25rem 0.75rem;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
  }

  /* Grounding Styles */

  .arcana-grounding-score {
    font-weight: 500;
    font-size: 0.75rem;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    margin-left: 0.5rem;
  }

  .arcana-grounding-score.good { background: #d1fae5; color: #065f46; }
  .arcana-grounding-score.warn { background: #fef3c7; color: #92400e; }
  .arcana-grounding-score.bad { background: #fee2e2; color: #991b1b; }

  .arcana-grounding-spans h5 {
    font-size: 0.8rem;
    font-weight: 600;
    color: #6b7280;
    margin: 0.75rem 0 0.5rem 0;
  }

  .arcana-span {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 0.5rem;
    padding: 0.375rem 0.5rem;
    border-radius: 0.375rem;
    margin-bottom: 0.25rem;
    font-size: 0.8rem;
  }

  .arcana-span.hallucinated {
    background: #fef2f2;
    border-left: 3px solid #ef4444;
  }

  .arcana-span.faithful {
    background: #f0fdf4;
    border-left: 3px solid #22c55e;
  }

  .arcana-span-text {
    font-family: ui-monospace, monospace;
    font-size: 0.8rem;
  }

  .arcana-span-score {
    font-size: 0.7rem;
    color: #9ca3af;
  }

  .arcana-span-sources {
    display: flex;
    gap: 0.25rem;
    flex-wrap: wrap;
    width: 100%;
  }

  .arcana-source-badge {
    font-size: 0.65rem;
    background: #f3f4f6;
    color: #6b7280;
    padding: 0.125rem 0.375rem;
    border-radius: 0.25rem;
  }

  .arcana-source-badge.clickable {
    cursor: pointer;
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    list-style: none;
  }

  .arcana-source-badge.clickable:hover {
    background: #e5e7eb;
  }

  .arcana-source-badge.clickable::-webkit-details-marker {
    display: none;
  }

  .arcana-source-label {
    font-weight: 600;
    color: #4b5563;
  }

  .arcana-source-overlap {
    color: #9ca3af;
  }

  .arcana-source-detail {
    display: inline;
  }

  .arcana-source-preview {
    font-size: 0.7rem;
    color: #4b5563;
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.25rem;
    padding: 0.5rem;
    margin-top: 0.375rem;
    margin-bottom: 0.25rem;
    line-height: 1.5;
    width: 100%;
  }

  /* Answer highlighting */
  .arcana-hl-hallucinated {
    background: #fecaca;
    border-bottom: 2px solid #ef4444;
    border-radius: 2px;
    padding: 0 1px;
  }

  .arcana-hl-faithful {
    background: #bbf7d0;
    border-bottom: 2px solid #22c55e;
    border-radius: 2px;
    padding: 0 1px;
  }

  /* Graph Tab Styles */
  .arcana-graph-subtabs {
    display: flex;
    gap: 0.5rem;
    margin-bottom: 1.5rem;
  }

  .arcana-subtab-btn {
    padding: 0.5rem 1rem;
    border: 1px solid #d1d5db;
    background: white;
    border-radius: 0.375rem;
    font-size: 0.875rem;
    cursor: pointer;
    transition: all 0.15s ease;
  }

  .arcana-subtab-btn:hover {
    border-color: #7c3aed;
    color: #7c3aed;
  }

  .arcana-subtab-btn.active {
    background: #7c3aed;
    border-color: #7c3aed;
    color: white;
  }

  .arcana-graph-table {
    margin-top: 1rem;
  }

  /* Entity type badges */
  .arcana-entity-type-badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
    text-transform: lowercase;
  }

  .arcana-entity-type-badge.person {
    background: #dbeafe;
    color: #1e40af;
  }

  .arcana-entity-type-badge.organization {
    background: #dcfce7;
    color: #166534;
  }

  .arcana-entity-type-badge.technology {
    background: #fce7f3;
    color: #9d174d;
  }

  .arcana-entity-type-badge.concept {
    background: #fef3c7;
    color: #92400e;
  }

  .arcana-entity-type-badge.location {
    background: #e0e7ff;
    color: #3730a3;
  }

  .arcana-entity-type-badge.event {
    background: #f3e8ff;
    color: #6b21a8;
  }

  /* Relationship strength meter */
  .arcana-strength-meter {
    display: inline-flex;
    gap: 2px;
    align-items: center;
  }

  .arcana-strength-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #e5e7eb;
  }

  .arcana-strength-dot.filled {
    background: #7c3aed;
  }

  /* Community status indicators */
  .arcana-status-ready {
    color: #16a34a;
  }

  .arcana-status-pending {
    color: #d97706;
  }

  .arcana-status-empty {
    color: #9ca3af;
  }

  .arcana-no-summary {
    color: #9ca3af;
    font-style: italic;
  }

  /* Graph empty state */
  .arcana-empty-state {
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.5rem;
    padding: 2rem;
    text-align: center;
  }

  .arcana-empty-state h3 {
    margin: 0 0 1rem 0;
    color: #374151;
  }

  .arcana-empty-state p {
    color: #6b7280;
    margin: 0.5rem 0;
  }

  .arcana-empty-state pre {
    background: #1f2937;
    color: #e5e7eb;
    padding: 0.75rem 1rem;
    border-radius: 0.375rem;
    display: inline-block;
    margin: 1rem 0;
    font-size: 0.875rem;
  }

  .arcana-empty-state code {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
  }

  /* Entity detail panel */
  .arcana-entity-row {
    cursor: pointer;
    transition: background-color 0.15s;
  }

  .arcana-entity-row.selected {
    background: #ede9fe;
  }

  .arcana-entity-detail {
    margin-top: 1.5rem;
    padding: 1.5rem;
    background: #faf5ff;
    border: 1px solid #e9d5ff;
    border-radius: 0.5rem;
  }

  .arcana-entity-detail-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 1rem;
  }

  .arcana-entity-detail-header h3 {
    margin: 0;
    font-size: 1.125rem;
    color: #1f2937;
  }

  .arcana-entity-detail-close {
    margin-left: auto;
    background: transparent;
    border: none;
    font-size: 1.5rem;
    color: #6b7280;
    cursor: pointer;
    padding: 0;
    line-height: 1;
  }

  .arcana-entity-detail-close:hover {
    color: #374151;
  }

  .arcana-entity-description {
    color: #4b5563;
    margin: 0 0 1rem 0;
  }

  .arcana-entity-relationships h4,
  .arcana-entity-mentions h4 {
    margin: 0 0 0.5rem 0;
    font-size: 0.875rem;
    color: #6b7280;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .arcana-rel-cards {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .arcana-rel-card {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 0.75rem;
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    font-size: 0.875rem;
  }

  .arcana-rel-type {
    font-family: monospace;
    background: #ede9fe;
    color: #5b21b6;
    padding: 0.125rem 0.5rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    font-weight: 600;
    text-transform: uppercase;
  }

  .arcana-rel-arrow {
    color: #9ca3af;
    font-weight: bold;
  }

  .arcana-rel-target,
  .arcana-rel-source {
    font-weight: 500;
    color: #1f2937;
  }

  .arcana-rel-self {
    color: #6b7280;
    font-style: italic;
    font-size: 0.75rem;
  }

  .arcana-mention-preview {
    background: white;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    padding: 0.75rem;
    margin-bottom: 0.5rem;
  }

  .arcana-mention-preview p {
    margin: 0 0 0.5rem 0;
    font-size: 0.875rem;
    color: #374151;
  }

  .arcana-view-in-docs {
    font-size: 0.75rem;
    color: #7c3aed;
    text-decoration: none;
  }

  .arcana-view-in-docs:hover {
    text-decoration: underline;
  }

  /* Relationship detail panel */
  .arcana-relationship-row {
    cursor: pointer;
    transition: background-color 0.15s;
  }

  .arcana-relationship-row.selected {
    background: #ede9fe;
  }

  .arcana-relationship-detail {
    margin-top: 1.5rem;
    padding: 1.5rem;
    background: #faf5ff;
    border: 1px solid #e9d5ff;
    border-radius: 0.5rem;
  }

  .arcana-relationship-detail-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
  }

  .arcana-relationship-visual {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 1rem;
  }

  .arcana-relationship-source,
  .arcana-relationship-target {
    font-weight: 600;
    color: #1f2937;
  }

  .arcana-relationship-arrow {
    color: #9ca3af;
  }

  .arcana-relationship-type {
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace;
    font-size: 0.875rem;
    background: #ede9fe;
    color: #6d28d9;
    padding: 0.25rem 0.5rem;
    border-radius: 0.25rem;
  }

  .arcana-relationship-detail-close {
    background: transparent;
    border: none;
    font-size: 1.5rem;
    color: #6b7280;
    cursor: pointer;
    padding: 0;
    line-height: 1;
  }

  .arcana-relationship-detail-close:hover {
    color: #374151;
  }

  .arcana-relationship-strength {
    margin-bottom: 0.75rem;
    color: #4b5563;
  }

  .arcana-relationship-description {
    color: #4b5563;
    margin: 0;
  }

  .arcana-empty-hint {
    font-size: 0.8125rem;
  }

  /* Community detail panel */
  .arcana-community-row {
    cursor: pointer;
    transition: background-color 0.15s;
  }

  .arcana-community-row.selected {
    background: #ede9fe;
  }

  .arcana-community-detail {
    margin-top: 1.5rem;
    padding: 1.5rem;
    background: #faf5ff;
    border: 1px solid #e9d5ff;
    border-radius: 0.5rem;
  }

  .arcana-community-detail-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 1rem;
  }

  .arcana-community-detail-header h3 {
    margin: 0;
    font-size: 1.125rem;
    color: #1f2937;
  }

  .arcana-community-level-badge {
    display: inline-block;
    padding: 0.125rem 0.5rem;
    border-radius: 9999px;
    font-size: 0.75rem;
    font-weight: 500;
    background: #ddd6fe;
    color: #5b21b6;
  }

  .arcana-community-detail-close {
    margin-left: auto;
    background: transparent;
    border: none;
    font-size: 1.5rem;
    color: #6b7280;
    cursor: pointer;
    padding: 0;
    line-height: 1;
  }

  .arcana-community-detail-close:hover {
    color: #374151;
  }

  .arcana-community-summary,
  .arcana-community-entities,
  .arcana-community-relationships {
    margin-bottom: 1rem;
  }

  .arcana-community-summary h4,
  .arcana-community-entities h4,
  .arcana-community-relationships h4 {
    margin: 0 0 0.5rem 0;
    font-size: 0.875rem;
    color: #6b7280;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .arcana-community-summary p {
    margin: 0;
    color: #374151;
    line-height: 1.5;
  }

  .arcana-community-entities ul,
  .arcana-community-relationships ul {
    list-style: none;
    padding: 0;
    margin: 0;
  }

  .arcana-community-entities li,
  .arcana-community-relationships li {
    padding: 0.5rem 0;
    border-bottom: 1px solid #e5e7eb;
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .arcana-community-entities li:last-child,
  .arcana-community-relationships li:last-child {
    border-bottom: none;
  }

  .arcana-community-no-summary {
    color: #9ca3af;
    font-style: italic;
  }

  /* Collection selector */
  .arcana-collection-selector {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    margin-bottom: 1rem;
  }

  .arcana-collection-selector label {
    font-size: 0.875rem;
    font-weight: 500;
    color: #374151;
  }

  .arcana-collection-selector select {
    padding: 0.5rem;
    border: 1px solid #d1d5db;
    border-radius: 0.375rem;
    font-size: 0.875rem;
    min-width: 200px;
  }

  .arcana-collection-selector select:focus {
    outline: none;
    border-color: #7c3aed;
    box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
  }

  /* Entity/Relationship/Community views */
  .arcana-entities-view,
  .arcana-relationships-view,
  .arcana-communities-view {
    margin-top: 1rem;
  }

  /* Deep Search toggle (simple mode, below textarea) */
  .arcana-deep-search-toggle {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.5rem 0.75rem;
    margin-top: 0.5rem;
    background: #f9fafb;
    border: 1px solid #e5e7eb;
    border-radius: 0.375rem;
    cursor: pointer;
    font-size: 0.8125rem;
  }

  .arcana-deep-search-toggle:hover {
    background: #f3f4f6;
  }

  .arcana-deep-search-toggle input[type="checkbox"] {
    accent-color: #7c3aed;
  }

  .arcana-deep-search-toggle span {
    font-weight: 500;
    color: #374151;
  }

  .arcana-deep-search-toggle small {
    color: #6b7280;
    font-size: 0.75rem;
  }

  /* Graph Context section */
  .arcana-graph-context {
    margin: 1.5rem 0;
    padding: 1rem;
    background: linear-gradient(to right, #faf5ff, #f3e8ff);
    border: 1px solid #e9d5ff;
    border-radius: 0.5rem;
  }

  .arcana-graph-context-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 0.5rem;
  }

  .arcana-graph-context-header h4 {
    margin: 0;
    color: #7c3aed;
    font-size: 1rem;
  }

  .arcana-toggle-btn {
    background: transparent;
    border: 1px solid #d8b4fe;
    border-radius: 0.25rem;
    padding: 0.25rem 0.5rem;
    cursor: pointer;
    color: #7c3aed;
    font-size: 0.75rem;
  }

  .arcana-toggle-btn:hover {
    background: #f3e8ff;
  }

  .arcana-no-matches {
    color: #9ca3af;
    font-style: italic;
    margin: 0.5rem 0;
  }

  .arcana-matched-entities,
  .arcana-matched-relationships {
    margin-top: 0.75rem;
  }

  .arcana-matched-entities h5,
  .arcana-matched-relationships h5 {
    margin: 0 0 0.5rem 0;
    font-size: 0.875rem;
    color: #6b21a8;
  }

  .arcana-matched-entities ul,
  .arcana-matched-relationships ul {
    list-style: none;
    padding: 0;
    margin: 0;
  }

  .arcana-matched-entities li,
  .arcana-matched-relationships li {
    padding: 0.375rem 0;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    border-bottom: 1px solid #f3e8ff;
  }

  .arcana-matched-entities li:last-child,
  .arcana-matched-relationships li:last-child {
    border-bottom: none;
  }

  .arcana-entity-name {
    font-weight: 500;
    color: #1f2937;
  }

  .arcana-entity-type {
    font-size: 0.75rem;
    padding: 0.125rem 0.5rem;
    background: #e9d5ff;
    color: #7c3aed;
    border-radius: 9999px;
  }

  .arcana-view-in-graph {
    margin-left: auto;
    font-size: 0.75rem;
    color: #7c3aed;
    text-decoration: none;
  }

  .arcana-view-in-graph:hover {
    text-decoration: underline;
  }

  .arcana-rel-source,
  .arcana-rel-target {
    color: #1f2937;
  }

  .arcana-rel-type {
    font-size: 0.75rem;
    color: #7c3aed;
    font-family: monospace;
  }

  /* Graph attribution in chunks */
  .arcana-graph-attribution {
    display: block;
    font-size: 0.75rem;
    color: #7c3aed;
    margin-top: 0.25rem;
    font-style: italic;
  }
  """
  @css_hash :crypto.hash(:md5, @css) |> Base.encode16(case: :lower) |> binary_part(0, 8)

  @doc """
  Returns the current hash for the given asset type.
  """
  def current_hash(:js), do: @js_hash
  def current_hash(:css), do: @css_hash

  @impl Plug
  def init(asset), do: asset

  @impl Plug
  def call(conn, asset) do
    {content, content_type} =
      case asset do
        :js -> {@js, "text/javascript"}
        :css -> {@css, "text/css"}
      end

    conn
    |> Plug.Conn.put_resp_header("content-type", content_type)
    |> Plug.Conn.put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> Plug.Conn.delete_resp_header("x-frame-options")
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
    |> Plug.Conn.send_resp(200, content)
  end
end
