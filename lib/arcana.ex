defmodule Arcana do
  @moduledoc """
  RAG (Retrieval Augmented Generation) library for Elixir.

  Arcana provides document ingestion, embedding, and vector search
  capabilities that you can embed into any Phoenix/Ecto application.

  ## Usage

      # Ingest a document
      {:ok, document} = Arcana.ingest("Your text content", repo: MyApp.Repo)

      # Search for relevant chunks
      {:ok, results} = Arcana.search("your query", repo: MyApp.Repo)

      # Ask questions with RAG
      {:ok, answer} = Arcana.ask("What is X?", repo: MyApp.Repo, llm: my_llm)

      # Delete a document
      :ok = Arcana.delete(document.id, repo: MyApp.Repo)

  ## Modules

    * `Arcana.Config` - Configuration management
    * `Arcana.Ingest` - Document ingestion
    * `Arcana.Search` - Vector and hybrid search
    * `Arcana.Ask` - RAG question answering
    * `Arcana.Graph` - GraphRAG functionality

  """

  alias Arcana.Document
  alias Arcana.Graph.GraphStore

  # === Configuration ===

  @doc """
  Returns the configured embedder as a `{module, opts}` tuple.
  See `Arcana.Config` for configuration options.
  """
  defdelegate embedder, to: Arcana.Config

  @doc """
  Returns the configured chunker as a `{module, opts}` tuple.
  See `Arcana.Config` for configuration options.
  """
  defdelegate chunker, to: Arcana.Config

  @doc """
  Returns the current Arcana configuration.
  """
  def config, do: Arcana.Config.current()

  @doc """
  Returns whether GraphRAG is enabled.
  """
  defdelegate graph_enabled?(opts), to: Arcana.Config

  # === Ingestion ===

  @doc """
  Ingests text content, creating a document with embedded chunks.
  See `Arcana.Ingest.ingest/2` for options.
  """
  defdelegate ingest(text, opts), to: Arcana.Ingest

  @doc """
  Ingests a file, parsing its content and creating a document with embedded chunks.
  See `Arcana.Ingest.ingest_file/2` for options.
  """
  defdelegate ingest_file(path, opts), to: Arcana.Ingest

  @doc """
  Ingests in-memory bytes, routing on the required `:filename` option's
  extension. See `Arcana.Ingest.ingest_binary/2` for options.
  """
  defdelegate ingest_binary(binary, opts), to: Arcana.Ingest

  # === Search ===

  @doc """
  Searches for chunks similar to the query.
  See `Arcana.Search.search/2` for options.
  """
  defdelegate search(query, opts), to: Arcana.Search

  @doc """
  Rewrites a query using a provided rewriter function.
  See `Arcana.Search.rewrite_query/2` for options.
  """
  defdelegate rewrite_query(query, opts \\ []), to: Arcana.Search

  # === RAG Q&A ===

  @doc """
  Asks a question using retrieved context from the knowledge base.
  See `Arcana.Ask.ask/2` for options.
  """
  defdelegate ask(question, opts), to: Arcana.Ask

  # === Document Management ===

  @doc """
  Lists documents, newest first. See `Arcana.Documents.list_documents/1`.
  """
  defdelegate list_documents(opts), to: Arcana.Documents

  @doc """
  Counts documents matching the `list_documents/1` filters.
  See `Arcana.Documents.count_documents/1`.
  """
  defdelegate count_documents(opts), to: Arcana.Documents

  @doc """
  Fetches a document by id. See `Arcana.Documents.get_document/2`.
  """
  defdelegate get_document(id, opts), to: Arcana.Documents

  @doc """
  Deletes a document and all its chunks.

  When the graph is enabled, also sweeps the document's collection for
  orphaned graph data: entities left with zero mentions are deleted and
  communities that referenced them are marked dirty so the next
  summarize pass regenerates them.

  Returns `:ok`, `{:error, :not_found}`, `{:error, {:sweep_failed, reason}}`
  when the graph store fails to sweep, or `{:error, reason}` for a database
  failure such as a foreign key violation from another table pointing at the
  document.

  A concurrent delete reports `{:error, :not_found}`, the same as losing that
  race by a moment more would have.

  Infrastructure failures — a lost connection, a pool timeout — still raise.
  There is nothing useful to hand back and the transaction's fate is unknown,
  so those are left to the caller's supervisor rather than flattened into a
  tuple that would read like a clean refusal.

  The delete and the orphan sweep run in one transaction, so a
  `:sweep_failed` leaves the document in place: nothing happened and the
  call can be retried. That is worth knowing if you are upgrading, because
  this case used to delete the document and report the failed cleanup
  afterwards.

  The transaction covers what runs on `:repo`. A custom graph store that
  keeps its data elsewhere is outside it, so a store that fails partway
  through its own sweep may have applied some of it even though the
  document survives.

  Sweeping is optional for custom graph stores: one that doesn't
  implement `c:Arcana.Graph.GraphStore.sweep_orphans/2` returns `:ok` and
  leaves the orphans alone.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:graph` - Sweep orphaned graph data after deletion (default: from config)

  """
  def delete(document_id, opts) do
    repo = Arcana.Config.require_repo!(opts)

    case repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      document ->
        delete_document(document, repo, opts)
    end
  end

  # repo.delete!/1 used to raise straight out of a function whose docs
  # promised error tuples, so a caller's case never saw a constraint
  # violation or a dropped connection. Callers sequence their own cleanup
  # around this call - removing a stored original, cancelling jobs - and had
  # no reason to expect control to leave abruptly.
  #
  # The sweep joins the same transaction so a failed cleanup no longer leaves
  # a deleted document behind it. Retrying is then the whole recovery.
  defp delete_document(document, repo, opts) do
    repo.transaction(fn ->
      case repo.delete(document) do
        {:ok, _deleted} ->
          case GraphStore.maybe_sweep_orphans(document.collection_id, repo, opts) do
            :ok -> :ok
            {:error, reason} -> repo.rollback({:sweep_failed, reason})
          end

        {:error, changeset} ->
          repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # The row went away between the get and the delete. A concurrent deleter
    # got there first, which is the same outcome the caller would have seen
    # had it lost the race by a moment more.
    Ecto.StaleEntryError ->
      {:error, :not_found}

    # repo.delete/1 only returns {:error, changeset} for a constraint the
    # changeset declared, and a host is free to point a foreign key at
    # arcana_documents from a table this library has never heard of. Those
    # arrive as Ecto.ConstraintError, which is the first case the docs
    # promised a tuple for.
    error in Ecto.ConstraintError ->
      {:error, error}
  end
end
