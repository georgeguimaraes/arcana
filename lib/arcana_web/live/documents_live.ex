# The dashboard is optional: this module only compiles when Phoenix
# LiveView is available (see the optional deps in mix.exs). Only
# ArcanaWeb.TaskSupervisor is phoenix-free and stays available.

if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule ArcanaWeb.DocumentsLive do
    @moduledoc """
    LiveView for managing documents in Arcana.
    """
    use Phoenix.LiveView

    require Logger

    import ArcanaWeb.DashboardComponents

    alias Arcana.{CollectionScope, Document}

    import Ecto.Query

    @impl true
    def mount(_params, session, socket) do
      repo = get_repo_from_session(session)
      graph_enabled = Arcana.Graph.enabled?()

      {:ok,
       socket
       |> assign(repo: repo)
       |> assign(page: 1, per_page: 10)
       |> assign(viewing_document: nil)
       |> assign(upload_error: nil)
       |> assign(filter_collection: nil)
       |> assign(graph_enabled: graph_enabled)
       # enabled? is config, installed? is the schema. The Build Graph button
       # renders on the former, so with the graph configured but never migrated
       # the click used to start a task that raised 42P01 and told nobody.
       #
       # Short-circuited so an app that does not use the graph pays nothing:
       # installed?/2 is a pg_class lookup on every mount of this page
       # otherwise. When the graph is off the button does not render, so the
       # guard below is only reachable by a forged event either way.
       |> assign(graph_installed: graph_enabled and Arcana.Graph.installed?(repo))
       |> assign(graph_indexing: false, graph_task: nil)
       |> assign(stats: nil, collections: [], documents: [], total_pages: 1, total_count: 0)
       |> allow_upload(:files,
         accept: ~w(.txt .md .markdown .pdf),
         max_entries: 10,
         max_file_size: 10_000_000
       )}
    end

    @impl true
    def handle_params(%{"doc" => doc_id}, _uri, socket) do
      socket = load_data(socket)
      {:noreply, load_document_detail(socket, doc_id)}
    end

    def handle_params(_params, _uri, socket) do
      {:noreply, load_data(socket)}
    end

    defp load_data(socket) do
      repo = socket.assigns.repo
      allowed = socket.assigns.allowed_collections

      socket
      |> assign(stats: load_stats(repo, allowed))
      |> assign(collections: load_collections(repo, allowed))
      |> load_documents()
    end

    defp load_documents(socket) do
      page = socket.assigns.page
      per_page = socket.assigns.per_page

      filters =
        [repo: socket.assigns.repo]
        |> Keyword.merge(
          collection_scope_opts(
            socket.assigns.allowed_collections,
            socket.assigns.filter_collection || :all
          )
        )

      {:ok, total_count} = Arcana.count_documents(filters)
      total_pages = max(1, ceil(total_count / per_page))

      {:ok, documents} =
        Arcana.list_documents(filters ++ [limit: per_page, offset: (page - 1) * per_page])

      assign(socket,
        documents: documents,
        total_pages: total_pages,
        total_count: total_count
      )
    end

    defp load_document_detail(socket, doc_id) do
      repo = socket.assigns.repo
      allowed = socket.assigns.allowed_collections

      case scoped_document(repo, doc_id, allowed) do
        {:ok, document} -> load_document_chunks(socket, document, doc_id)
        {:error, :not_found} -> socket
      end
    end

    defp collection_scope_opts(allowed, requested) do
      requested_scope = CollectionScope.normalize!(requested)
      allowed_scope = CollectionScope.normalize!(allowed)

      case CollectionScope.intersect(requested_scope, allowed_scope) do
        :all -> [collection: :all]
        {:only, names} -> [collections: names]
      end
    end

    defp load_document_chunks(socket, document, doc_id) do
      repo = socket.assigns.repo
      chunks = scoped_chunks(repo, doc_id, socket.assigns.allowed_collections)

      assign(socket, viewing_document: %{document: document, chunks: chunks})
    end

    defp scoped_document(repo, doc_id, allowed) do
      case Ecto.UUID.cast(doc_id) do
        {:ok, uuid} -> fetch_scoped_document(repo, uuid, allowed)
        :error -> {:error, :not_found}
      end
    end

    defp fetch_scoped_document(repo, document_id, allowed) do
      document =
        Document
        |> where([row], row.id == ^document_id)
        |> apply_document_scope(allowed)
        |> preload([:collection])
        |> repo.one()

      if document, do: {:ok, document}, else: {:error, :not_found}
    end

    defp scoped_chunks(repo, doc_id, allowed) do
      Arcana.Chunk
      |> join(:inner, [chunk], document in assoc(chunk, :document))
      |> where([chunk], chunk.document_id == ^doc_id)
      |> apply_chunk_scope(allowed)
      |> order_by([chunk], chunk.chunk_index)
      |> repo.all()
    end

    defp apply_document_scope(query, allowed) do
      case CollectionScope.normalize!(allowed) do
        :all ->
          query

        {:only, []} ->
          where(query, [document], is_nil(document.id))

        {:only, names} ->
          query
          |> join(:inner, [document], collection in assoc(document, :collection))
          |> where([_document, collection], collection.name in ^names)
      end
    end

    defp apply_chunk_scope(query, allowed) do
      case CollectionScope.normalize!(allowed) do
        :all ->
          query

        {:only, []} ->
          where(query, [chunk, _document], is_nil(chunk.id))

        {:only, names} ->
          query
          |> join(:inner, [_chunk, document], collection in assoc(document, :collection))
          |> where([_chunk, _document, collection], collection.name in ^names)
      end
    end

    # A forged id that isn't a UUID can't match anything, so it's rejected
    # before it reaches a query that would raise on the cast.
    defp delete_document(socket, id) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> delete_document(socket, uuid, socket.assigns.allowed_collections)
        :error -> :error
      end
    end

    defp delete_document(socket, uuid, :all) do
      case Arcana.delete(uuid, repo: socket.assigns.repo) do
        :ok -> :ok
        {:error, _reason} -> :error
      end
    end

    # Restricted deletes are a single statement: the allowed-collection
    # predicate rides inside the DELETE, so a rename that moves the
    # collection out of scope between the allow-check and the delete can't
    # slip through a stale decision. Zero rows affected means the document
    # wasn't in scope (or never existed) and the event is rejected. Chunks
    # and graph rows cascade at the database level, same as
    # `Arcana.delete/2`.
    defp delete_document(socket, uuid, allowed) do
      allowed_ids = from(c in Arcana.Collection, where: c.name in ^allowed, select: c.id)

      query =
        from(d in Document,
          where: d.id == ^uuid and d.collection_id in subquery(allowed_ids)
        )

      case socket.assigns.repo.delete_all(query) do
        {0, _} -> :error
        {_count, _} -> :ok
      end
    end

    @impl true
    def handle_event("change_page", %{"page" => page}, socket) do
      page = String.to_integer(page)
      {:noreply, socket |> assign(page: page) |> load_documents()}
    end

    def handle_event("view_document", %{"id" => id}, socket) do
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:noreply, load_document_detail(socket, uuid)}
        :error -> {:noreply, socket}
      end
    end

    def handle_event("close_detail", _params, socket) do
      {:noreply, assign(socket, viewing_document: nil)}
    end

    def handle_event("ingest", params, socket) do
      repo = socket.assigns.repo
      content = params["content"] || ""
      format = parse_format(params["format"])
      collection = normalize_collection(params["collection"])
      graph = params["graph"] == "true"

      if allowed_collection?(socket.assigns.allowed_collections, collection) do
        {:ok, _doc} =
          Arcana.ingest(content, repo: repo, format: format, collection: collection, graph: graph)

        {:noreply, load_data(socket)}
      else
        {:noreply, put_flash(socket, :error, "Collection #{inspect(collection)} is not allowed")}
      end
    end

    def handle_event("upload_files", params, socket) do
      collection = normalize_collection(params["collection"])

      if allowed_collection?(socket.assigns.allowed_collections, collection) do
        {:noreply, ingest_uploads(socket, collection, params["graph"] == "true")}
      else
        {:noreply,
         assign(socket, upload_error: "Collection #{inspect(collection)} is not allowed")}
      end
    end

    def handle_event("cancel_upload", %{"ref" => ref}, socket) do
      {:noreply, cancel_upload(socket, :files, ref)}
    end

    def handle_event("validate_upload", _params, socket) do
      {:noreply, socket}
    end

    def handle_event("delete", %{"id" => id}, socket) do
      case delete_document(socket, id) do
        :ok -> {:noreply, load_data(socket)}
        :error -> {:noreply, socket}
      end
    end

    def handle_event("filter_by_collection", %{"collection" => collection_name}, socket) do
      if allowed_collection?(socket.assigns.allowed_collections, collection_name) do
        {:noreply,
         socket |> assign(filter_collection: collection_name, page: 1) |> load_documents()}
      else
        {:noreply, socket}
      end
    end

    def handle_event("clear_collection_filter", _params, socket) do
      {:noreply, socket |> assign(filter_collection: nil, page: 1) |> load_documents()}
    end

    # Only reachable from the open document detail panel; a forged event
    # with no document open has nothing to build a graph from.
    def handle_event("build_graph", _params, %{assigns: %{viewing_document: nil}} = socket) do
      {:noreply, socket}
    end

    # A build already running. The button renders disabled while graph_indexing
    # is true so this is not reachable by clicking, but a forged or raced event
    # would otherwise start a second task and overwrite graph_task: the first
    # completion would then demonitor the *second* task, dropping its
    # failure monitoring and clearing the spinner out from under it.
    def handle_event("build_graph", _params, %{assigns: %{graph_indexing: true}} = socket) do
      {:noreply, socket}
    end

    def handle_event("build_graph", _params, %{assigns: %{graph_installed: false}} = socket) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "GraphRAG is not installed in this database. Run a migration calling " <>
           "Arcana.Graph.Migration.up/1 to build a graph."
       )}
    end

    def handle_event("build_graph", _params, socket) do
      document_id = socket.assigns.viewing_document.document.id

      case scoped_document(
             socket.assigns.repo,
             document_id,
             socket.assigns.allowed_collections
           ) do
        {:ok, document} ->
          chunks =
            scoped_chunks(
              socket.assigns.repo,
              document_id,
              socket.assigns.allowed_collections
            )

          start_graph_build(socket, document, chunks)

        {:error, :not_found} ->
          {:noreply,
           socket
           |> assign(viewing_document: nil)
           |> put_flash(:error, "This document is no longer available.")}
      end
    end

    defp start_graph_build(socket, document, chunks) do
      collection = document.collection
      repo = socket.assigns.repo
      parent = self()
      run_ref = make_ref()

      started =
        ArcanaWeb.BackgroundTask.start(
          parent,
          :graph_complete,
          fn ->
            # The task is supervised, not linked to this LiveView, so a failure
            # in here dies silently: no {:graph_complete, _} arrives and
            # graph_indexing stays true, spinning forever. Report it instead.
            #
            # `catch` rather than `rescue`, for the reason Arcana.Ingest gives at
            # build_graph_or_fail_document/5: an extractor or store is as free to
            # throw or exit as to raise, and a GenServer.call timeout exits. A
            # rescue here left an exiting extractor stranding the spinner exactly
            # the way the missing schema did.
            result =
              try do
                Arcana.Graph.build_and_persist(chunks, collection, repo, [])
              catch
                kind, reason ->
                  Logger.error(
                    "Arcana: graph build failed for document #{document.id}: " <>
                      Exception.format(kind, reason, __STACKTRACE__)
                  )

                  {:error, Exception.format_banner(kind, reason)}
              end

            result
          end,
          run_ref: run_ref
        )

      case started do
        {:ok, task} ->
          # The catch above enumerates the ways the build itself fails. A
          # monitor covers the ways it stops without running our code at all -
          # the supervisor shutting the task down, an external kill, the node
          # running out of memory - so the spinner clears on every termination
          # kind rather than on the list we thought of.
          #
          # The ref is kept so the DOWN clause can tell this task's death from
          # any other monitor's: clearing the spinner on someone else's DOWN
          # would flash a graph error for an unrelated process.
          {:noreply, assign(socket, graph_indexing: true, graph_task: task)}

        {:error, reason} ->
          # The supervisor can refuse (max_children, or it is not running).
          # Turning the spinner on first and matching {:ok, _} here took the
          # whole LiveView down instead, which is worse than the hang this
          # function exists to fix.
          Logger.error("Arcana: could not start the graph build task: #{inspect(reason)}")

          {:noreply,
           socket
           |> assign(graph_indexing: false, graph_task: nil)
           |> put_flash(:error, "Could not start the graph build: #{inspect(reason)}")}
      end
    end

    defp ingest_uploads(socket, collection, graph) do
      repo = socket.assigns.repo

      uploaded_files =
        consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
          dest = Path.join(System.tmp_dir!(), "arcana_#{entry.uuid}_#{entry.client_name}")
          File.cp!(path, dest)
          {:ok, dest}
        end)

      results =
        Enum.map(uploaded_files, fn path ->
          result = Arcana.ingest_file(path, repo: repo, collection: collection, graph: graph)
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

      load_data(socket)
    end

    # Only the graph task's own DOWN, matched on the stored ref. The reported
    # path demonitors with :flush below, so reaching here at all means the task
    # died without sending a result.
    @impl true
    def handle_info(
          {:DOWN, ref, :process, _pid, reason},
          %{assigns: %{graph_task: %{monitor_ref: ref}}} = socket
        ) do
      {:noreply,
       socket
       |> assign(graph_indexing: false, graph_task: nil)
       |> put_flash(:error, "Graph build stopped: #{inspect(reason)}")}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

    @impl true
    def handle_info(
          {:graph_complete, run_ref, result},
          %{assigns: %{graph_task: %{run_ref: run_ref, monitor_ref: monitor_ref}}} = socket
        ) do
      # The task reported, so its DOWN carries no information. Flush it rather
      # than leaving a stale message to be matched against a later build's ref.
      Process.demonitor(monitor_ref, [:flush])

      socket = assign(socket, graph_task: nil)

      socket =
        case result do
          {:ok, %{entity_count: entities, relationship_count: relationships}} ->
            socket
            |> assign(graph_indexing: false)
            |> put_flash(
              :info,
              "Graph built: #{entities} entities, #{relationships} relationships"
            )

          {:error, reason} ->
            socket
            |> assign(graph_indexing: false)
            |> put_flash(:error, "Graph build failed: #{inspect(reason)}")
        end

      {:noreply, socket}
    end

    def handle_info({:graph_complete, _run_ref, _result}, socket), do: {:noreply, socket}

    @impl true
    def render(assigns) do
      ~H"""
      <.dashboard_layout flash={@flash} stats={@stats} current_tab={:documents} prefix={@prefix}>
        <div class="arcana-documents">
          <%= if @viewing_document do %>
            <.document_detail
              viewing={@viewing_document}
              graph_enabled={@graph_enabled}
              graph_indexing={@graph_indexing}
            />
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
                        <%= if allowed_collection?(@allowed_collections, "default") do %>
                          <option value="">default</option>
                        <% end %>
                        <%= for collection <- @collections do %>
                          <option value={collection.name}><%= collection.name %></option>
                        <% end %>
                      </select>
                    </label>
                    <div class="arcana-graph-toggle">
                      <label>
                        Build Graph
                        <label class="arcana-checkbox-label">
                          <input type="checkbox" name="graph" value="true" />
                          <span>Extract entities and relationships</span>
                        </label>
                      </label>
                    </div>
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
                    <%= if allowed_collection?(@allowed_collections, "default") do %>
                      <option value="">default</option>
                    <% end %>
                    <%= for collection <- @collections do %>
                      <option value={collection.name}><%= collection.name %></option>
                    <% end %>
                  </select>
                </label>
                <div class="arcana-graph-toggle">
                  <label>
                    Build Graph
                    <label class="arcana-checkbox-label">
                      <input type="checkbox" name="graph" value="true" />
                      <span>Extract entities and relationships</span>
                    </label>
                  </label>
                </div>
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
                      <td class="arcana-actions-cell">
                        <button
                          data-view-doc={doc.id}
                          class="arcana-icon-btn"
                          phx-click="view_document"
                          phx-value-id={doc.id}
                          title="View document"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                            <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path>
                            <circle cx="12" cy="12" r="3"></circle>
                          </svg>
                        </button>
                        <button
                          data-delete-doc={doc.id}
                          class="arcana-delete-btn"
                          phx-click="delete"
                          phx-value-id={doc.id}
                          title="Delete document"
                        >
                          <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                            <polyline points="3 6 5 6 21 6"></polyline>
                            <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
                            <line x1="10" y1="11" x2="10" y2="17"></line>
                            <line x1="14" y1="11" x2="14" y2="17"></line>
                          </svg>
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>

              <%= if @total_pages > 1 do %>
                <div class="arcana-pagination">
                  <button
                    class="arcana-page-btn"
                    phx-click="change_page"
                    phx-value-page={@page - 1}
                    disabled={@page <= 1}
                  >
                    &lsaquo; Prev
                  </button>
                  <%= for entry <- page_window(@page, @total_pages) do %>
                    <%= case entry do %>
                      <% :ellipsis -> %>
                        <span class="arcana-page-ellipsis">&hellip;</span>
                      <% page -> %>
                        <button
                          data-page={page}
                          class={"arcana-page-btn #{if page == @page, do: "active", else: ""}"}
                          phx-click="change_page"
                          phx-value-page={page}
                        >
                          <%= format_number(page) %>
                        </button>
                    <% end %>
                  <% end %>
                  <button
                    class="arcana-page-btn"
                    phx-click="change_page"
                    phx-value-page={@page + 1}
                    disabled={@page >= @total_pages}
                  >
                    Next &rsaquo;
                  </button>
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
          <div class="arcana-doc-header-actions">
            <%= if @graph_enabled do %>
              <button
                phx-click="build_graph"
                disabled={@graph_indexing}
                class="arcana-graph-btn"
                style="background: #10b981; color: white; padding: 0.5rem 1rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; margin-right: 0.5rem;"
              >
                <%= if @graph_indexing, do: "Building...", else: "Build Graph" %>
              </button>
            <% end %>
            <button class="arcana-close-btn" phx-click="close_detail">← Back to list</button>
          </div>
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

    defp page_window(current, total, window \\ 2) do
      around =
        max(2, current - window)..min(total - 1, current + window)
        |> Enum.to_list()

      [1 | around]
      |> then(fn pages -> if total > 1, do: pages ++ [total], else: pages end)
      |> Enum.uniq()
      |> Enum.sort()
      |> insert_ellipsis()
    end

    defp insert_ellipsis([a, b | rest]) when b - a > 1,
      do: [a, :ellipsis | insert_ellipsis([b | rest])]

    defp insert_ellipsis([a | rest]), do: [a | insert_ellipsis(rest)]
    defp insert_ellipsis([]), do: []
  end
end
