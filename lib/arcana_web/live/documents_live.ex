defmodule ArcanaWeb.DocumentsLive do
  @moduledoc """
  LiveView for managing documents in Arcana.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  alias Arcana.Document

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(page: 1, per_page: 10)
     |> assign(viewing_document: nil)
     |> assign(upload_error: nil)
     |> assign(filter_collection: nil)
     |> allow_upload(:files,
       accept: ~w(.txt .md .markdown .pdf),
       max_entries: 10,
       max_file_size: 10_000_000
     )
     |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> assign(collections: load_collections(repo))
    |> load_documents()
  end

  defp load_documents(socket) do
    repo = socket.assigns.repo
    page = socket.assigns.page
    per_page = socket.assigns.per_page
    filter_collection = socket.assigns.filter_collection
    import Ecto.Query

    base_query =
      from(d in Document,
        order_by: [desc: d.inserted_at],
        preload: [:collection]
      )

    filtered_query =
      if filter_collection do
        from(d in base_query,
          join: c in assoc(d, :collection),
          where: c.name == ^filter_collection
        )
      else
        base_query
      end

    total_count = repo.aggregate(filtered_query, :count)
    total_pages = max(1, ceil(total_count / per_page))

    documents =
      repo.all(
        from(d in filtered_query,
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

  @impl true
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
    collection = normalize_collection(params["collection"])

    {:ok, _doc} = Arcana.ingest(content, repo: repo, format: format, collection: collection)
    {:noreply, load_data(socket)}
  end

  def handle_event("upload_files", params, socket) do
    repo = socket.assigns.repo
    collection = normalize_collection(params["collection"])

    uploaded_files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        dest = Path.join(System.tmp_dir!(), "arcana_#{entry.uuid}_#{entry.client_name}")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    results =
      Enum.map(uploaded_files, fn path ->
        result = Arcana.ingest_file(path, repo: repo, collection: collection)
        File.rm(path)
        result
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    socket =
      if Enum.empty?(errors) do
        assign(socket, upload_error: nil)
      else
        error_msg =
          Enum.map_join(errors, ", ", fn {:error, reason} -> inspect(reason) end)

        assign(socket, upload_error: "Some files failed: #{error_msg}")
      end

    {:noreply, load_data(socket)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case Arcana.delete(id, repo: repo) do
      :ok -> {:noreply, load_data(socket)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("filter_by_collection", %{"collection" => collection_name}, socket) do
    {:noreply, socket |> assign(filter_collection: collection_name, page: 1) |> load_documents()}
  end

  def handle_event("clear_collection_filter", _params, socket) do
    {:noreply, socket |> assign(filter_collection: nil, page: 1) |> load_documents()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:documents}>
      <div class="arcana-documents">
        <%= if @viewing_document do %>
          <.document_detail viewing={@viewing_document} />
        <% else %>
          <h2>Documents</h2>
          <p class="arcana-tab-description">
            Upload, view, and manage documents in your knowledge base.
          </p>

          <div class="arcana-upload-section">
            <form id="upload-form" phx-submit="upload_files" phx-change="validate_upload">
              <div class="arcana-dropzone" phx-drop-target={@uploads.files.ref}>
                <.live_file_input upload={@uploads.files} class="arcana-file-input" />
                <p>Drag & drop files here or click to browse</p>
                <p class="arcana-upload-hint">Supported: .txt, .md, .pdf (max 10MB each)</p>
              </div>

              <%= if @upload_error do %>
                <p class="arcana-upload-error"><%= @upload_error %></p>
              <% end %>

              <%= for entry <- @uploads.files.entries do %>
                <div class="arcana-upload-entry">
                  <span><%= entry.client_name %></span>
                  <progress value={entry.progress} max="100"><%= entry.progress %>%</progress>
                  <button type="button" phx-click="cancel_upload" phx-value-ref={entry.ref}>&times;</button>

                  <%= for err <- upload_errors(@uploads.files, entry) do %>
                    <span class="arcana-upload-error"><%= error_to_string(err) %></span>
                  <% end %>
                </div>
              <% end %>

              <%= if length(@uploads.files.entries) > 0 do %>
                <div class="arcana-ingest-options">
                  <label>
                    Collection
                    <select name="collection">
                      <option value="">default</option>
                      <%= for collection <- @collections do %>
                        <option value={collection.name}><%= collection.name %></option>
                      <% end %>
                    </select>
                  </label>
                </div>
                <button type="submit" class="arcana-upload-btn">Upload Files</button>
              <% end %>
            </form>
          </div>

          <div class="arcana-divider">or paste text directly</div>

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
              <label>
                Collection
                <select name="collection">
                  <option value="">default</option>
                  <%= for collection <- @collections do %>
                    <option value={collection.name}><%= collection.name %></option>
                  <% end %>
                </select>
              </label>
            </div>
            <button type="submit">Ingest</button>
          </form>

          <%= if not Enum.empty?(@collections) do %>
            <div class="arcana-filter-bar">
              <span class="arcana-filter-label">Filter by collection:</span>
              <%= for collection <- @collections do %>
                <button
                  id={"filter-collection-#{collection.name}"}
                  class={"arcana-filter-btn #{if @filter_collection == collection.name, do: "active", else: ""}"}
                  phx-click="filter_by_collection"
                  phx-value-collection={collection.name}
                >
                  <%= collection.name %>
                </button>
              <% end %>
              <%= if @filter_collection do %>
                <button
                  id="clear-collection-filter"
                  class="arcana-filter-btn arcana-filter-clear"
                  phx-click="clear_collection_filter"
                >
                  ✕ Clear
                </button>
              <% end %>
            </div>
          <% end %>

          <%= if Enum.empty?(@documents) do %>
            <p class="arcana-empty">No documents yet. Paste some text above to get started.</p>
          <% else %>
            <table class="arcana-documents-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Content</th>
                  <th>Collection</th>
                  <th>Source</th>
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
                    <td><%= if doc.collection, do: doc.collection.name, else: "-" %></td>
                    <td><%= doc.source_id || "-" %></td>
                    <td><%= doc.chunk_count %></td>
                    <td><%= doc.inserted_at %></td>
                    <td>
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
    </.dashboard_layout>
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
end
