defmodule ArcanaWeb.DashboardLive do
  @moduledoc """
  LiveView for the Arcana dashboard.

  Provides tabs for managing documents and searching.
  """
  use Phoenix.LiveView

  alias Arcana.{Collection, Document}
  alias Arcana.Evaluation

  @impl true
  def mount(_params, session, socket) do
    repo =
      session["repo"] || Application.get_env(:arcana, :repo) ||
        raise "Missing :arcana, :repo config"

    socket =
      socket
      |> assign(tab: :documents, repo: repo)
      |> assign(search_results: [], search_query: "")
      |> assign(expanded_result_id: nil, viewing_search_document: nil)
      |> assign(
        agentic_question: "",
        agentic_running: false,
        agentic_context: nil,
        agentic_error: nil
      )
      |> assign(page: 1, per_page: 10)
      |> assign(viewing_document: nil)
      |> assign(upload_error: nil)
      |> assign(
        eval_view: :test_cases,
        eval_running: false,
        eval_generating: false,
        eval_message: nil
      )
      |> assign(
        reembed_running: false,
        reembed_progress: nil,
        embedding_info: get_embedding_info()
      )
      |> assign(config_info: get_config_info())
      |> allow_upload(:files,
        accept: ~w(.txt .md .markdown .pdf),
        max_entries: 10,
        max_file_size: 10_000_000
      )
      |> assign(selected_collection: nil)
      |> assign(editing_collection: nil, confirm_delete_collection: nil)
      |> assign(filter_collection: nil)
      |> load_collections()
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
    collection = normalize_collection(params["collection"])

    {:ok, _doc} = Arcana.ingest(content, repo: repo, format: format, collection: collection)
    {:noreply, socket |> load_documents() |> load_collections() |> load_stats()}
  end

  def handle_event("upload_files", params, socket) do
    repo = socket.assigns.repo
    collection = normalize_collection(params["collection"])

    uploaded_files =
      consume_uploaded_entries(socket, :files, fn %{path: path}, entry ->
        # Copy to a permanent location since the temp file will be deleted
        dest = Path.join(System.tmp_dir!(), "arcana_#{entry.uuid}_#{entry.client_name}")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    # Ingest each uploaded file
    results =
      Enum.map(uploaded_files, fn path ->
        result = Arcana.ingest_file(path, repo: repo, collection: collection)
        # Clean up the temp file
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

    {:noreply, socket |> load_documents() |> load_collections() |> load_stats()}
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
    collection = if params["collection"] in [nil, ""], do: nil, else: params["collection"]
    mode = parse_mode(params["mode"])

    results =
      if query != "" do
        opts = [repo: repo, limit: limit, threshold: threshold, mode: mode]
        opts = if source_id, do: Keyword.put(opts, :source_id, source_id), else: opts
        opts = if collection, do: Keyword.put(opts, :collection, collection), else: opts
        Arcana.search(query, opts)
      else
        []
      end

    {:noreply, assign(socket, search_results: results, search_query: query, expanded_result_id: nil)}
  end

  def handle_event("toggle_result", %{"id" => id}, socket) do
    current = socket.assigns.expanded_result_id
    new_id = if current == id, do: nil, else: id
    {:noreply, assign(socket, expanded_result_id: new_id)}
  end

  def handle_event("view_search_document", %{"id" => id}, socket) do
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

    {:noreply, assign(socket, viewing_search_document: %{document: document, chunks: chunks})}
  end

  def handle_event("close_search_document", _params, socket) do
    {:noreply, assign(socket, viewing_search_document: nil)}
  end

  def handle_event("agentic_search", params, socket) do
    repo = socket.assigns.repo
    question = params["question"] || ""

    case Application.get_env(:arcana, :llm) do
      nil ->
        {:noreply,
         assign(socket,
           agentic_error: "No LLM configured. Set :arcana, :llm in your config.",
           agentic_running: false
         )}

      llm ->
        if question == "" do
          {:noreply, assign(socket, agentic_error: "Please enter a question")}
        else
          socket = assign(socket, agentic_running: true, agentic_error: nil, agentic_question: question)
          parent = self()

          # Parse options from form
          use_select = params["use_select"] == "true"
          use_expand = params["use_expand"] == "true"
          use_decompose = params["use_decompose"] == "true"
          use_rerank = params["use_rerank"] == "true"
          self_correct = params["self_correct"] == "true"

          Task.start(fn ->
            result = run_agentic_pipeline(
              question,
              repo,
              llm,
              socket.assigns.collections,
              use_select: use_select,
              use_expand: use_expand,
              use_decompose: use_decompose,
              use_rerank: use_rerank,
              self_correct: self_correct
            )
            send(parent, {:agentic_complete, result})
          end)

          {:noreply, socket}
        end
    end
  end

  def handle_event("agentic_clear", _params, socket) do
    {:noreply, assign(socket, agentic_context: nil, agentic_error: nil, agentic_question: "")}
  end

  def handle_event("eval_switch_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, eval_view: String.to_existing_atom(view))}
  end

  def handle_event("eval_run", params, socket) do
    repo = socket.assigns.repo
    mode = parse_mode(params["mode"])
    evaluate_answers = params["evaluate_answers"] == "true"

    # Check if LLM is configured when evaluate_answers is requested
    llm = Application.get_env(:arcana, :llm)

    if evaluate_answers and is_nil(llm) do
      {:noreply,
       assign(socket,
         eval_message: {:error, "No LLM configured. Set :arcana, :llm in your config."}
       )}
    else
      socket = assign(socket, eval_running: true, eval_message: nil)
      opts = build_run_opts(repo, mode, evaluate_answers, llm)

      case Evaluation.run(opts) do
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
  end

  defp build_run_opts(repo, mode, false, _llm), do: [repo: repo, mode: mode]

  defp build_run_opts(repo, mode, true, llm) do
    [repo: repo, mode: mode, evaluate_answers: true, llm: llm]
  end

  def handle_event("eval_generate", params, socket) do
    repo = socket.assigns.repo
    sample_size = parse_int(params["sample_size"], 10)

    case Application.get_env(:arcana, :llm) do
      nil ->
        {:noreply,
         assign(socket,
           eval_message: {:error, "No LLM configured. Set :arcana, :llm in your config."}
         )}

      llm ->
        socket = assign(socket, eval_generating: true, eval_message: nil)

        # Run generation in a Task to avoid blocking
        parent = self()

        Task.start(fn ->
          result = Evaluation.generate_test_cases(repo: repo, llm: llm, sample_size: sample_size)
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

  def handle_event("reembed", _params, socket) do
    repo = socket.assigns.repo
    parent = self()

    socket = assign(socket, reembed_running: true, reembed_progress: %{current: 0, total: 0})

    Task.start(fn ->
      progress_fn = fn current, total ->
        send(parent, {:reembed_progress, current, total})
      end

      result = Arcana.Maintenance.reembed(repo, batch_size: 50, progress: progress_fn)
      send(parent, {:reembed_complete, result})
    end)

    {:noreply, socket}
  end

  # Collection CRUD events
  def handle_event("create_collection", %{"collection" => params}, socket) do
    repo = socket.assigns.repo
    name = params["name"] || ""
    description = params["description"]

    case Collection.get_or_create(name, repo, description) do
      {:ok, _collection} ->
        {:noreply, load_collections(socket)}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Failed to create collection: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("edit_collection", %{"id" => id}, socket) do
    repo = socket.assigns.repo
    collection = repo.get(Collection, id)
    {:noreply, assign(socket, editing_collection: collection)}
  end

  def handle_event("cancel_edit_collection", _params, socket) do
    {:noreply, assign(socket, editing_collection: nil)}
  end

  def handle_event("update_collection", %{"id" => id, "collection" => params}, socket) do
    repo = socket.assigns.repo
    collection = repo.get!(Collection, id)

    changeset =
      Collection.changeset(collection, %{
        name: params["name"] || collection.name,
        description: params["description"]
      })

    case repo.update(changeset) do
      {:ok, _updated} ->
        {:noreply, socket |> assign(editing_collection: nil) |> load_collections()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update: #{inspect(changeset.errors)}")}
    end
  end

  def handle_event("confirm_delete_collection", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_delete_collection: id)}
  end

  def handle_event("cancel_delete_collection", _params, socket) do
    {:noreply, assign(socket, confirm_delete_collection: nil)}
  end

  def handle_event("delete_collection", %{"id" => id}, socket) do
    repo = socket.assigns.repo

    case repo.get(Collection, id) do
      nil ->
        {:noreply, assign(socket, confirm_delete_collection: nil)}

      collection ->
        repo.delete!(collection)

        {:noreply,
         socket
         |> assign(confirm_delete_collection: nil)
         |> load_collections()
         |> load_documents()}
    end
  end

  # Document filtering events
  def handle_event("filter_by_collection", %{"collection" => collection_name}, socket) do
    {:noreply, socket |> assign(filter_collection: collection_name, page: 1) |> load_documents()}
  end

  def handle_event("clear_collection_filter", _params, socket) do
    {:noreply, socket |> assign(filter_collection: nil, page: 1) |> load_documents()}
  end

  @impl true
  def handle_info({:reembed_progress, current, total}, socket) do
    {:noreply, assign(socket, reembed_progress: %{current: current, total: total})}
  end

  def handle_info({:reembed_complete, result}, socket) do
    socket =
      case result do
        {:ok, %{reembedded: count}} ->
          socket
          |> assign(reembed_running: false, reembed_progress: nil)
          |> put_flash(:info, "Re-embedded #{count} chunks successfully!")

        {:error, reason} ->
          socket
          |> assign(reembed_running: false, reembed_progress: nil)
          |> put_flash(:error, "Re-embedding failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agentic_complete, result}, socket) do
    socket =
      case result do
        {:ok, ctx} ->
          assign(socket, agentic_running: false, agentic_context: ctx, agentic_error: nil)

        {:error, reason} ->
          assign(socket, agentic_running: false, agentic_error: inspect(reason))
      end

    {:noreply, socket}
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

  defp normalize_collection(""), do: "default"
  defp normalize_collection(nil), do: "default"
  defp normalize_collection(name) when is_binary(name), do: name

  defp format_metadata(nil), do: "-"
  defp format_metadata(metadata) when metadata == %{}, do: "-"

  defp format_metadata(metadata) when is_map(metadata) do
    Enum.map_join(metadata, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp error_to_string(:too_large), do: "File too large (max 10MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 10)"
  defp error_to_string(:not_accepted), do: "File type not supported"
  defp error_to_string(err), do: "Error: #{inspect(err)}"

  defp run_agentic_pipeline(question, repo, llm, collections, opts) do
    alias Arcana.Agent

    collection_names = Enum.map(collections, & &1.name)

    try do
      ctx = Agent.new(question, repo: repo, llm: llm)

      # Apply optional pipeline steps
      ctx =
        if Keyword.get(opts, :use_select, false) and length(collection_names) > 0 do
          Agent.select(ctx, collections: collection_names)
        else
          ctx
        end

      ctx =
        if Keyword.get(opts, :use_expand, false) do
          Agent.expand(ctx)
        else
          ctx
        end

      ctx =
        if Keyword.get(opts, :use_decompose, false) do
          Agent.decompose(ctx)
        else
          ctx
        end

      # Search with optional self-correction
      ctx = Agent.search(ctx, self_correct: Keyword.get(opts, :self_correct, false))

      # Optional reranking
      ctx =
        if Keyword.get(opts, :use_rerank, false) do
          Agent.rerank(ctx)
        else
          ctx
        end

      # Generate answer
      ctx = Agent.answer(ctx)

      if ctx.error do
        {:error, ctx.error}
      else
        {:ok, ctx}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp load_documents(socket) do
    repo = socket.assigns.repo
    page = socket.assigns.page
    per_page = socket.assigns.per_page
    filter_collection = socket.assigns.filter_collection
    import Ecto.Query

    # Base query
    base_query =
      from(d in Document,
        order_by: [desc: d.inserted_at],
        preload: [:collection]
      )

    # Apply collection filter if set
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

  defp load_collections(socket) do
    repo = socket.assigns.repo
    import Ecto.Query

    collections =
      repo.all(
        from(c in Collection,
          left_join: d in Document,
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

    assign(socket, collections: collections)
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
          data-tab="collections"
          class={"arcana-tab #{if @tab == :collections, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="collections"
        >
          Collections
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
          data-tab="agentic"
          class={"arcana-tab #{if @tab == :agentic, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="agentic"
        >
          Agentic
        </button>
        <button
          data-tab="evaluation"
          class={"arcana-tab #{if @tab == :evaluation, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="evaluation"
        >
          Evaluation
        </button>
        <button
          data-tab="maintenance"
          class={"arcana-tab #{if @tab == :maintenance, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="maintenance"
        >
          Maintenance
        </button>
        <button
          data-tab="info"
          class={"arcana-tab #{if @tab == :info, do: "active", else: ""}"}
          phx-click="switch_tab"
          phx-value-tab="info"
        >
          Info
        </button>
      </nav>

      <div class="arcana-content">
        <%= case @tab do %>
          <% :documents -> %>
            <.documents_tab
              documents={@documents}
              page={@page}
              total_pages={@total_pages}
              viewing={@viewing_document}
              uploads={@uploads}
              upload_error={@upload_error}
              collections={@collections}
              filter_collection={@filter_collection}
            />
          <% :collections -> %>
            <.collections_tab
              collections={@collections}
              editing_collection={@editing_collection}
              confirm_delete={@confirm_delete_collection}
            />
          <% :search -> %>
            <.search_tab
              results={@search_results}
              query={@search_query}
              source_ids={@source_ids}
              collections={@collections}
              expanded_result_id={@expanded_result_id}
              viewing_document={@viewing_search_document}
            />
          <% :agentic -> %>
            <.agentic_tab
              question={@agentic_question}
              running={@agentic_running}
              context={@agentic_context}
              error={@agentic_error}
              collections={@collections}
            />
          <% :evaluation -> %>
            <.evaluation_tab
              view={@eval_view}
              test_cases={@eval_test_cases}
              runs={@eval_runs}
              test_case_count={@eval_test_case_count}
              running={@eval_running}
              generating={@eval_generating}
              message={@eval_message}
            />
          <% :maintenance -> %>
            <.maintenance_tab
              embedding_info={@embedding_info}
              reembed_running={@reembed_running}
              reembed_progress={@reembed_progress}
            />
          <% :info -> %>
            <.info_tab config_info={@config_info} />
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
      <%= if @viewing_document do %>
        <.search_document_detail viewing={@viewing_document} />
      <% else %>
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

              <label>
                Collection
                <select name="collection">
                  <option value="">All collections</option>
                  <%= for collection <- @collections do %>
                    <option value={collection.name}><%= collection.name %></option>
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
          <div class="arcana-search-results">
            <%= for result <- @results do %>
              <div class="arcana-search-result">
                <div class="arcana-result-header">
                  <div class="arcana-result-score">
                    <span class="score-value"><%= Float.round(result.score, 4) %></span>
                  </div>
                  <div class="arcana-result-meta">
                    <code><%= result.document_id %></code>
                    <span class="arcana-chunk-badge">Chunk <%= result.chunk_index %></span>
                  </div>
                  <div class="arcana-result-actions">
                    <button
                      class="arcana-result-btn"
                      phx-click="toggle_result"
                      phx-value-id={result.id}
                    >
                      <%= if @expanded_result_id == result.id, do: "Collapse", else: "Expand" %>
                    </button>
                    <button
                      class="arcana-result-btn arcana-result-btn-primary"
                      phx-click="view_search_document"
                      phx-value-id={result.document_id}
                    >
                      View Doc
                    </button>
                  </div>
                </div>
                <div class={"arcana-result-text #{if @expanded_result_id == result.id, do: "expanded", else: ""}"}>
                  <%= if @expanded_result_id == result.id do %>
                    <%= result.text %>
                  <% else %>
                    <%= String.slice(result.text, 0, 200) %><%= if String.length(result.text) > 200, do: "...", else: "" %>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp search_document_detail(assigns) do
    ~H"""
    <div class="arcana-doc-detail">
      <div class="arcana-doc-header">
        <h2>Document Details</h2>
        <button class="arcana-close-btn" phx-click="close_search_document">← Back to search</button>
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

  defp agentic_tab(assigns) do
    ~H"""
    <div class="arcana-agentic">
      <h2>Agentic Search</h2>
      <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
        Use the agentic pipeline for more sophisticated search with LLM-powered query expansion,
        decomposition, and answer generation.
      </p>

      <%= if @error do %>
        <div class="arcana-eval-message error">
          <%= @error %>
        </div>
      <% end %>

      <form id="agentic-form" phx-submit="agentic_search" class="arcana-agentic-form">
        <div class="arcana-agentic-input">
          <textarea
            name="question"
            placeholder="Ask a question about your documents..."
            rows="3"
            disabled={@running}
          ><%= @question %></textarea>
        </div>

        <div class="arcana-agentic-options">
          <h4>Pipeline Options</h4>
          <div class="arcana-option-grid">
            <label class="arcana-checkbox-label">
              <input type="checkbox" name="use_select" value="true" disabled={@running or Enum.empty?(@collections)} />
              <span>Collection Selection</span>
              <small>LLM selects relevant collections</small>
            </label>

            <label class="arcana-checkbox-label">
              <input type="checkbox" name="use_expand" value="true" disabled={@running} />
              <span>Query Expansion</span>
              <small>Generate related queries</small>
            </label>

            <label class="arcana-checkbox-label">
              <input type="checkbox" name="use_decompose" value="true" disabled={@running} />
              <span>Question Decomposition</span>
              <small>Break into sub-questions</small>
            </label>

            <label class="arcana-checkbox-label">
              <input type="checkbox" name="self_correct" value="true" disabled={@running} />
              <span>Self-Correction</span>
              <small>Refine search if results are poor</small>
            </label>

            <label class="arcana-checkbox-label">
              <input type="checkbox" name="use_rerank" value="true" disabled={@running} />
              <span>Reranking</span>
              <small>LLM-based result reranking</small>
            </label>
          </div>
        </div>

        <div class="arcana-agentic-actions">
          <button type="submit" disabled={@running}>
            <%= if @running, do: "Searching...", else: "Ask" %>
          </button>
          <%= if @context do %>
            <button type="button" phx-click="agentic_clear" disabled={@running}>
              Clear
            </button>
          <% end %>
        </div>
      </form>

      <%= if @running do %>
        <div class="arcana-agentic-loading">
          <div class="arcana-spinner"></div>
          <span>Running agentic pipeline...</span>
        </div>
      <% end %>

      <%= if @context do %>
        <div class="arcana-agentic-results">
          <div class="arcana-agentic-answer">
            <h3>Answer</h3>
            <div class="arcana-answer-content">
              <%= if @context.answer do %>
                <%= @context.answer %>
              <% else %>
                <span style="color: #9ca3af; font-style: italic;">No answer generated</span>
              <% end %>
            </div>
          </div>

          <%= if @context.queries && length(@context.queries) > 1 do %>
            <div class="arcana-agentic-section">
              <h4>Expanded Queries</h4>
              <ul class="arcana-query-list">
                <%= for query <- @context.queries do %>
                  <li><%= query %></li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if @context.sub_questions && length(@context.sub_questions) > 0 do %>
            <div class="arcana-agentic-section">
              <h4>Sub-Questions</h4>
              <ul class="arcana-query-list">
                <%= for sq <- @context.sub_questions do %>
                  <li><%= sq %></li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if @context.selected_collections && length(@context.selected_collections) > 0 do %>
            <div class="arcana-agentic-section">
              <h4>Selected Collections</h4>
              <div class="arcana-collection-badges">
                <%= for coll <- @context.selected_collections do %>
                  <span class="arcana-collection-badge"><%= coll %></span>
                <% end %>
              </div>
            </div>
          <% end %>

          <%= if @context.results && length(@context.results) > 0 do %>
            <div class="arcana-agentic-section">
              <h4>Retrieved Chunks (<%= length(@context.results) %>)</h4>
              <div class="arcana-search-results">
                <%= for result <- @context.results do %>
                  <div class="arcana-search-result">
                    <div class="arcana-result-header">
                      <div class="arcana-result-score">
                        <span class="score-value"><%= Float.round(result.score, 4) %></span>
                      </div>
                      <div class="arcana-result-meta">
                        <code><%= result.document_id %></code>
                        <span class="arcana-chunk-badge">Chunk <%= result.chunk_index %></span>
                      </div>
                    </div>
                    <div class="arcana-result-text">
                      <%= String.slice(result.text, 0, 300) %><%= if String.length(result.text) > 300, do: "...", else: "" %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>

    <style>
      .arcana-agentic-form {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1.5rem;
      }

      .arcana-agentic-input textarea {
        width: 100%;
        padding: 0.75rem;
        border: 1px solid #d1d5db;
        border-radius: 0.375rem;
        font-size: 0.875rem;
        resize: vertical;
        box-sizing: border-box;
      }

      .arcana-agentic-input textarea:focus {
        outline: none;
        border-color: #7c3aed;
        box-shadow: 0 0 0 3px rgba(124, 58, 237, 0.1);
      }

      .arcana-agentic-options {
        margin-top: 1rem;
        padding-top: 1rem;
        border-top: 1px solid #e5e7eb;
      }

      .arcana-agentic-options h4 {
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

      .arcana-agentic-actions {
        display: flex;
        gap: 0.5rem;
        margin-top: 1rem;
      }

      .arcana-agentic-actions button {
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

      .arcana-agentic-actions button:hover {
        background: #6d28d9;
      }

      .arcana-agentic-actions button:disabled {
        background: #9ca3af;
        cursor: not-allowed;
      }

      .arcana-agentic-actions button[type="button"] {
        background: transparent;
        color: #6b7280;
        border: 1px solid #d1d5db;
      }

      .arcana-agentic-actions button[type="button"]:hover {
        border-color: #7c3aed;
        color: #7c3aed;
        background: transparent;
      }

      .arcana-agentic-loading {
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

      .arcana-agentic-results {
        margin-top: 1.5rem;
      }

      .arcana-agentic-answer {
        background: white;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        overflow: hidden;
        margin-bottom: 1rem;
      }

      .arcana-agentic-answer h3 {
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

      .arcana-agentic-section {
        background: #f9fafb;
        border: 1px solid #e5e7eb;
        border-radius: 0.5rem;
        padding: 1rem;
        margin-bottom: 1rem;
      }

      .arcana-agentic-section h4 {
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
    </style>
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
          <.eval_test_cases_view test_cases={@test_cases} generating={@generating} />
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
      <form phx-submit="eval_generate" class="arcana-run-form" style="margin-bottom: 1.5rem;">
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

        <label style="display: flex; align-items: center; gap: 0.5rem;">
          <input type="checkbox" name="evaluate_answers" value="true" />
          Evaluate Answers
          <span style="font-size: 0.75rem; color: #6b7280;">(requires LLM)</span>
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
                  <%= if run.metrics["faithfulness"] || run.metrics[:faithfulness] do %>
                    <div class="arcana-metric-card">
                      <div class="arcana-metric-value"><%= format_score(run.metrics["faithfulness"] || run.metrics[:faithfulness]) %></div>
                      <div class="arcana-metric-label">Faithfulness</div>
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

  defp format_pct(nil), do: "-"
  defp format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  defp format_pct(value) when is_integer(value), do: "#{value}%"

  defp format_score(nil), do: "-"
  defp format_score(value) when is_float(value), do: "#{Float.round(value, 1)}/10"
  defp format_score(value) when is_integer(value), do: "#{value}/10"

  defp get_embedding_info do
    Arcana.Maintenance.embedding_info()
  rescue
    _ -> %{type: :unknown, dimensions: nil}
  end

  defp maintenance_tab(assigns) do
    ~H"""
    <div class="arcana-maintenance">
      <h2>Maintenance</h2>

      <div class="arcana-maintenance-section">
        <h3>Embedding Configuration</h3>
        <div class="arcana-doc-info">
          <div class="arcana-doc-field">
            <label>Type</label>
            <span><%= @embedding_info.type %></span>
          </div>
          <%= if @embedding_info[:model] do %>
            <div class="arcana-doc-field">
              <label>Model</label>
              <span><%= @embedding_info.model %></span>
            </div>
          <% end %>
          <div class="arcana-doc-field">
            <label>Dimensions</label>
            <span><%= @embedding_info.dimensions || "Unknown" %></span>
          </div>
        </div>
      </div>

      <div class="arcana-maintenance-section">
        <h3>Re-embed All Chunks</h3>
        <p style="color: #6b7280; margin-bottom: 1rem; font-size: 0.875rem;">
          Re-embed all chunks using the current embedding configuration.
          Use this after changing embedding models.
        </p>

        <%= if @reembed_running do %>
          <div class="arcana-progress">
            <div class="arcana-progress-text">
              Re-embedding... <%= @reembed_progress.current %>/<%= @reembed_progress.total %>
            </div>
            <%= if @reembed_progress.total > 0 do %>
              <progress
                value={@reembed_progress.current}
                max={@reembed_progress.total}
                style="width: 100%; height: 1rem;"
              >
                <%= round(@reembed_progress.current / @reembed_progress.total * 100) %>%
              </progress>
            <% end %>
          </div>
        <% else %>
          <button
            phx-click="reembed"
            class="arcana-reembed-btn"
            style="background: #7c3aed; color: white; padding: 0.625rem 1.25rem; border: none; border-radius: 0.375rem; font-size: 0.875rem; font-weight: 500; cursor: pointer;"
          >
            Re-embed All Chunks
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  defp get_config_info do
    %{
      repo: Application.get_env(:arcana, :repo),
      llm: format_llm_config(Application.get_env(:arcana, :llm)),
      embedding: format_embedding_config(Application.get_env(:arcana, :embedding, :local)),
      reranker: format_reranker_config(Application.get_env(:arcana, :reranker))
    }
  end

  defp format_llm_config(nil), do: %{configured: false}

  defp format_llm_config(llm) when is_function(llm) do
    %{configured: true, type: "Function"}
  end

  defp format_llm_config(llm) do
    case llm do
      %{__struct__: module} = struct ->
        %{
          configured: true,
          type: module |> Module.split() |> List.last(),
          model: Map.get(struct, :model, "unknown")
        }

      _ ->
        %{configured: true, type: inspect(llm)}
    end
  end

  defp format_embedding_config(:local), do: %{type: :local, model: "BAAI/bge-small-en-v1.5"}
  defp format_embedding_config(:openai), do: %{type: :openai, model: "text-embedding-3-small"}

  defp format_embedding_config({:local, opts}) do
    %{type: :local, model: Keyword.get(opts, :model, "BAAI/bge-small-en-v1.5")}
  end

  defp format_embedding_config({:openai, opts}) do
    %{type: :openai, model: Keyword.get(opts, :model, "text-embedding-3-small")}
  end

  defp format_embedding_config({:custom, _fun}), do: %{type: :custom}
  defp format_embedding_config({:custom, _fun, _opts}), do: %{type: :custom}

  defp format_embedding_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{type: :custom_module, module: module, opts: opts}
  end

  defp format_embedding_config(module) when is_atom(module) do
    %{type: :custom_module, module: module}
  end

  defp format_embedding_config(other), do: %{type: :unknown, raw: inspect(other)}

  defp format_reranker_config(nil), do: %{module: Arcana.Reranker.LLM, configured: false}

  defp format_reranker_config(module) when is_atom(module),
    do: %{module: module, configured: true}

  defp format_reranker_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{module: module, opts: opts, configured: true}
  end

  defp format_reranker_config(fun) when is_function(fun) do
    %{type: :function, configured: true}
  end

  defp format_reranker_config(other), do: %{type: :unknown, raw: inspect(other), configured: true}

  defp collections_tab(assigns) do
    ~H"""
    <div class="arcana-collections">
      <h2>Collections</h2>

      <div class="arcana-ingest-form">
        <h3>Create Collection</h3>
        <form id="new-collection-form" phx-submit="create_collection">
          <div class="arcana-form-row" style="margin-bottom: 0.75rem;">
            <input
              type="text"
              name="collection[name]"
              placeholder="Collection name"
              class="arcana-input"
              style="flex: 1; max-width: 300px;"
              required
            />
          </div>
          <div class="arcana-form-row">
            <input
              type="text"
              name="collection[description]"
              placeholder="Description (optional) - helps the agent select the right collection"
              class="arcana-input"
              style="flex: 1;"
            />
            <button type="submit" class="arcana-btn arcana-btn-primary">
              Create
            </button>
          </div>
        </form>
      </div>

      <div class="arcana-doc-list">
        <%= if Enum.empty?(@collections) do %>
          <div class="arcana-empty">No collections yet. Create one above.</div>
        <% else %>
          <table class="arcana-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Description</th>
                <th>Documents</th>
                <th style="width: 120px;">Actions</th>
              </tr>
            </thead>
            <tbody>
              <%= for collection <- @collections do %>
                <tr id={"collection-#{collection.name}"}>
                  <%= if @editing_collection && @editing_collection.id == collection.id do %>
                    <td colspan="4">
                      <form
                        id={"edit-collection-form-#{collection.id}"}
                        phx-submit="update_collection"
                        phx-value-id={collection.id}
                        class="arcana-edit-form"
                      >
                        <div class="arcana-form-row">
                          <input
                            type="text"
                            name="collection[name]"
                            value={collection.name}
                            class="arcana-input"
                            disabled
                          />
                          <input
                            type="text"
                            name="collection[description]"
                            value={collection.description || ""}
                            placeholder="Description"
                            class="arcana-input"
                            style="flex: 2;"
                          />
                          <button type="submit" class="arcana-btn arcana-btn-primary">Save</button>
                          <button
                            type="button"
                            class="arcana-btn"
                            phx-click="cancel_edit_collection"
                          >
                            Cancel
                          </button>
                        </div>
                      </form>
                    </td>
                  <% else %>
                    <td><code><%= collection.name %></code></td>
                    <td><%= collection.description || "-" %></td>
                    <td>
                      <%= collection.document_count %> <%= if collection.document_count == 1, do: "document", else: "documents" %>
                    </td>
                    <td>
                      <%= if @confirm_delete == collection.id do %>
                        <div class="arcana-confirm-delete">
                          <span>Delete?</span>
                          <button
                            id="confirm-delete"
                            class="arcana-btn arcana-btn-danger"
                            phx-click="delete_collection"
                            phx-value-id={collection.id}
                          >
                            Yes
                          </button>
                          <button
                            class="arcana-btn"
                            phx-click="cancel_delete_collection"
                          >
                            No
                          </button>
                        </div>
                      <% else %>
                        <button
                          id={"edit-collection-#{collection.id}"}
                          class="arcana-btn"
                          phx-click="edit_collection"
                          phx-value-id={collection.id}
                        >
                          Edit
                        </button>
                        <button
                          id={"delete-collection-#{collection.id}"}
                          class="arcana-btn arcana-btn-danger"
                          phx-click="confirm_delete_collection"
                          phx-value-id={collection.id}
                        >
                          Delete
                        </button>
                      <% end %>
                    </td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp info_tab(assigns) do
    ~H"""
    <div class="arcana-info">
      <h2>Configuration</h2>

      <div class="arcana-info-section">
        <h3>Repository</h3>
        <div class="arcana-doc-info">
          <div class="arcana-doc-field">
            <label>Module</label>
            <code><%= inspect(@config_info.repo) %></code>
          </div>
        </div>
      </div>

      <div class="arcana-info-section">
        <h3>Embedding</h3>
        <div class="arcana-doc-info">
          <div class="arcana-doc-field">
            <label>Type</label>
            <span><%= @config_info.embedding.type %></span>
          </div>
          <%= if @config_info.embedding[:model] do %>
            <div class="arcana-doc-field">
              <label>Model</label>
              <span><%= @config_info.embedding.model %></span>
            </div>
          <% end %>
          <%= if @config_info.embedding[:module] do %>
            <div class="arcana-doc-field">
              <label>Module</label>
              <code><%= inspect(@config_info.embedding.module) %></code>
            </div>
          <% end %>
        </div>
      </div>

      <div class="arcana-info-section">
        <h3>LLM</h3>
        <div class="arcana-doc-info">
          <%= if @config_info.llm.configured do %>
            <div class="arcana-doc-field">
              <label>Type</label>
              <span><%= @config_info.llm.type %></span>
            </div>
            <%= if @config_info.llm[:model] do %>
              <div class="arcana-doc-field">
                <label>Model</label>
                <span><%= @config_info.llm.model %></span>
              </div>
            <% end %>
          <% else %>
            <div class="arcana-doc-field">
              <label>Status</label>
              <span style="color: #9ca3af;">Not configured</span>
            </div>
          <% end %>
        </div>
      </div>

      <div class="arcana-info-section">
        <h3>Reranker</h3>
        <div class="arcana-doc-info">
          <div class="arcana-doc-field">
            <label>Module</label>
            <code><%= inspect(@config_info.reranker[:module] || @config_info.reranker[:type]) %></code>
          </div>
          <%= if @config_info.reranker[:opts] do %>
            <div class="arcana-doc-field">
              <label>Options</label>
              <span><%= inspect(@config_info.reranker.opts) %></span>
            </div>
          <% end %>
          <div class="arcana-doc-field">
            <label>Status</label>
            <span><%= if @config_info.reranker.configured, do: "Configured", else: "Default" %></span>
          </div>
        </div>
      </div>

      <div class="arcana-info-section">
        <h3>Raw Configuration</h3>
        <pre class="arcana-doc-content" style="font-size: 0.75rem;">config :arcana,
    repo: <%= inspect(@config_info.repo) %>,
    embedding: <%= inspect(Application.get_env(:arcana, :embedding, :local)) %>,
    llm: <%= if Application.get_env(:arcana, :llm), do: inspect(Application.get_env(:arcana, :llm)), else: "nil" %>,
    reranker: <%= if Application.get_env(:arcana, :reranker), do: inspect(Application.get_env(:arcana, :reranker)), else: "Arcana.Reranker.LLM (default)" %></pre>
      </div>
    </div>
    """
  end
end
