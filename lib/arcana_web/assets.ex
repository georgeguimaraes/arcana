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
  let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
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

  .arcana-documents-table button {
    background: transparent;
    padding: 0.375rem 0.75rem;
    border-radius: 0.25rem;
    font-size: 0.75rem;
    cursor: pointer;
    transition: all 0.15s ease;
    color: #dc2626;
    border: 1px solid #dc2626;
  }

  .arcana-documents-table button:hover {
    background: #dc2626;
    color: white;
  }

  .arcana-documents-table .arcana-view-btn {
    color: #7c3aed;
    border-color: #7c3aed;
  }

  .arcana-documents-table .arcana-view-btn:hover {
    background: #7c3aed;
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
    align-items: center;
  }

  .arcana-brand {
    font-size: 1.25rem;
    font-weight: 700;
    letter-spacing: -0.025em;
    padding-right: 1rem;
    border-right: 1px solid rgba(255, 255, 255, 0.3);
    margin-right: 0.5rem;
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

  .arcana-actions-cell {
    display: flex;
    gap: 0.25rem;
    align-items: center;
  }

  .arcana-icon-btn {
    flex-shrink: 0;
    display: flex;
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
    flex-shrink: 0;
    display: flex;
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

  .arcana-option-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 0.75rem;
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
    padding: 1rem;
    font-size: 0.875rem;
    line-height: 1.6;
    white-space: pre-wrap;
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
