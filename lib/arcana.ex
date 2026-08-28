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

  import Ecto.Query, only: [from: 2]

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
  when the graph store *returns* an error from its sweep, or
  `{:error, reason}` for a database failure such as a foreign key violation,
  or a not-null violation from another table pointing at the document.

  A sweep that raises a *database* error reports as a database failure rather
  than as `:sweep_failed` — so match `{:error, _}` as well if you route on the
  sweep case. `sweep_orphans/2` deletes through `repo.delete_all/1`, which
  skips changeset constraint mapping, so a host row referencing an entity the
  sweep wants to remove arrives that way.

  When an external graph store is cleaned after the database delete commits,
  a returned error or exception is wrapped as
  `{:error, {:post_commit_graph_cleanup_failed, context}}`. The context carries
  `:reason`, `:chunk_ids`, `:published_chunk_ids`, and `:collection_id`, so the
  graph deletion and sweep can be retried even though the document row is
  already gone.

  A concurrent delete reports `{:error, :not_found}`, the same as losing that
  race by a moment more would have.

  Infrastructure failures — a lost connection, a pool timeout — still raise.
  There is nothing useful to hand back and the transaction's fate is unknown,
  so those are left to the caller's supervisor rather than flattened into a
  tuple that would read like a clean refusal.

  Called on its own, the delete and the orphan sweep run in one transaction,
  so a `:sweep_failed` leaves the document in place: nothing happened and the
  call can be retried. That is worth knowing if you are upgrading, because
  this case used to delete the document and report the failed cleanup
  afterwards. Inside a transaction of your own it behaves differently — see
  below.

  The transaction covers what runs on `:repo`. A graph store holding its data
  anywhere else is outside it — that includes the built-in `:memory` backend,
  whose sweep is a `GenServer.call`, not only custom stores. So the two can
  disagree in both directions: a store that fails partway through its own
  sweep may have applied some of it even though the document survives, and a
  store that sweeps successfully before the repo side rolls back has dropped
  graph data for a document that is still there.

  ## Inside a transaction of your own

  It does not open one, and it does not roll anything back: rolling back a
  nested Ecto transaction aborts the outermost one, which would kill your
  transaction while handing you an error that looks recoverable.

  So the guarantee above is weaker here. A `:sweep_failed` comes back as a
  tuple with your transaction intact, but **the delete has been applied** and
  stays in your transaction's scope — undoing it is yours to do. That is the
  one place where `:sweep_failed` does not mean "nothing happened".

  A database failure is harsher: Postgres aborts to the nearest savepoint, and
  with none open that is the whole transaction, so the error ends it whatever
  gets returned. If you need to survive one, set your own savepoint around the
  call:

      Repo.query!("SAVEPOINT before_delete")

      case Arcana.delete(id, repo: Repo) do
        {:error, _reason} -> Repo.query!("ROLLBACK TO SAVEPOINT before_delete")
        :ok -> Repo.query!("RELEASE SAVEPOINT before_delete")
      end

  That recovers every failure the built-in stores can produce: a failed
  `repo.delete`, a `:sweep_failed`, and a sweep that raises.

  A custom graph store can still defeat it, by opening a nested `Ecto`
  transaction of its own around work that then fails — DBConnection marks the
  connection aborted, and the `ROLLBACK TO SAVEPOINT` is refused along with
  everything else. Calling `delete/2` outside your transaction avoids the
  question entirely.

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
  # Two shapes on purpose. Standalone, this owns a transaction so a failed
  # sweep takes the delete with it. Inside a caller's transaction, it must not:
  # repo.rollback/1 in a nested Ecto transaction aborts the OUTERMOST one, so
  # forcing it here would kill the caller's transaction while handing back a
  # tuple that reads like a recoverable refusal. Their transaction already
  # provides the atomicity, and the error is theirs to act on.
  defp delete_document(document, repo, opts) do
    cond do
      repo.in_transaction?() and external_graph_cleanup?(document, opts) ->
        {:error, :external_graph_store_requires_post_commit_delete}

      repo.in_transaction?() ->
        locked_delete(document, repo, opts)

      external_graph_cleanup?(document, opts) ->
        delete_before_external_cleanup(document, repo, opts)

      true ->
        repo.transaction(fn ->
          case locked_delete(document, repo, opts) do
            :ok -> :ok
            {:error, reason} -> repo.rollback(reason)
          end
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
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

    # And Ecto only builds a ConstraintError out of fk/unique/check/exclusion
    # codes. A host foreign key declared ON DELETE SET NULL against a NOT NULL
    # column raises 23502 instead, and a host BEFORE DELETE trigger can raise
    # anything - both are "another table pointing at the document", which the
    # docs promise a tuple for. Postgrex.Error is SQL-level only, so a dropped
    # connection or a pool timeout is a different struct and still raises.
    error in Postgrex.Error ->
      {:error, error}
  end

  defp external_graph_cleanup?(document, opts) do
    sweeping?(document, opts) and not ecto_graph_store?(opts)
  end

  defp delete_before_external_cleanup(document, repo, opts) do
    GraphStore.with_write_lock(
      document.collection_id,
      Keyword.put(opts, :repo, repo),
      fn -> delete_and_cleanup_external_graph(document, repo, opts) end
    )
    |> case do
      {:ok, {chunk_ids, locked_document}} ->
        sweep_external_graph(chunk_ids, locked_document, repo, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_and_cleanup_external_graph(document, repo, opts) do
    repo.transaction(fn ->
      locked_document =
        repo.one(from(d in Document, where: d.id == ^document.id, lock: "FOR UPDATE"))

      if locked_document do
        chunk_ids =
          repo.all(
            from(c in Arcana.Chunk, where: c.document_id == ^locked_document.id, select: c.id)
          )

        case repo.delete(locked_document) do
          {:ok, deleted} -> {chunk_ids, deleted}
          {:error, reason} -> repo.rollback(reason)
        end
      else
        repo.rollback(:not_found)
      end
    end)
    |> case do
      {:ok, {chunk_ids, locked_document}} ->
        case delete_external_graph_chunks(chunk_ids, locked_document, repo, opts) do
          :ok -> {:ok, {chunk_ids, locked_document}}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_external_graph_chunks(chunk_ids, document, repo, opts) do
    graph_opts =
      opts
      |> Keyword.put(:repo, repo)
      |> Keyword.put(:published_chunk_ids, published_chunk_ids(document, chunk_ids))

    case GraphStore.delete_by_chunks(chunk_ids, graph_opts) do
      :ok -> :ok
      {:error, reason} -> post_commit_graph_cleanup_error(reason, document, chunk_ids)
    end
  rescue
    exception -> post_commit_graph_cleanup_error(exception, document, chunk_ids)
  catch
    :exit, reason -> post_commit_graph_cleanup_error(reason, document, chunk_ids)
    kind, reason -> post_commit_graph_cleanup_error({kind, reason}, document, chunk_ids)
  end

  defp sweep_external_graph(chunk_ids, document, repo, opts) do
    case sweep(document, repo, opts) do
      :ok -> :ok
      {:error, reason} -> post_commit_graph_cleanup_error(reason, document, chunk_ids)
    end
  rescue
    exception -> post_commit_graph_cleanup_error(exception, document, chunk_ids)
  catch
    :exit, reason -> post_commit_graph_cleanup_error(reason, document, chunk_ids)
    kind, reason -> post_commit_graph_cleanup_error({kind, reason}, document, chunk_ids)
  end

  defp post_commit_graph_cleanup_error(reason, document, chunk_ids) do
    {:error,
     {:post_commit_graph_cleanup_failed,
      %{
        reason: reason,
        chunk_ids: chunk_ids,
        published_chunk_ids: published_chunk_ids(document, chunk_ids),
        collection_id: document.collection_id
      }}}
  end

  defp published_chunk_ids(%Document{status: :completed}, chunk_ids), do: chunk_ids
  defp published_chunk_ids(_document, _chunk_ids), do: []

  # The advisory lock goes first, before any row locks, because that is the
  # order the build side takes them (Arcana.Graph.persist_chunk_graph/6 holds
  # the write lock and then writes mentions that reference arcana_chunks).
  #
  # Deleting first and sweeping second reverses it: the cascade holds chunk row
  # locks, then asks for the advisory lock a concurrent build already has,
  # while that build waits on the chunk rows. That deadlocks, and it is a
  # regression from taking one transaction across both - repo.delete!/1 used to
  # autocommit and release the row locks before the sweep asked for anything.
  defp locked_delete(document, repo, opts) do
    if sweeping?(document, opts) and ecto_graph_store?(opts) do
      GraphStore.with_write_lock(
        document.collection_id,
        Keyword.put(opts, :repo, repo),
        fn -> delete_and_sweep(document, repo, opts) end
      )
    else
      delete_and_sweep(document, repo, opts)
    end
  end

  # The same condition maybe_sweep_orphans/3 uses, so a delete that will not
  # sweep does not take a graph lock it has no use for.
  defp sweeping?(document, opts) do
    !is_nil(document.collection_id) and Arcana.Config.graph_enabled?(opts)
  end

  # Only the :ecto store reaches this in-transaction lock path. External stores
  # lock around the transaction before calling locked_delete/3, then sweep
  # after releasing that non-reentrant lock.
  defp ecto_graph_store?(opts) do
    case Keyword.get(opts, :graph_store, GraphStore.backend()) do
      :ecto -> true
      {:ecto, _opts} -> true
      _other -> false
    end
  end

  defp delete_and_sweep(document, repo, opts) do
    chunk_ids =
      repo.all(from(c in Arcana.Chunk, where: c.document_id == ^document.id, select: c.id))

    with :ok <- cleanup_graph_before_delete(chunk_ids, document, repo, opts),
         {:ok, _deleted} <- repo.delete(document),
         :ok <- cleanup_graph_after_delete(chunk_ids, document, repo, opts) do
      maybe_sweep_after_delete(document, repo, opts)
    end
  end

  defp maybe_sweep_after_delete(document, repo, opts) do
    # Ecto's delete_by_chunks/2 already sweeps the affected collections in
    # the transaction that removes their mentions. External stores keep the
    # explicit pass because their delete callback does not own that contract.
    if sweeping?(document, opts) and ecto_graph_store?(opts) do
      :ok
    else
      sweep(document, repo, opts)
    end
  end

  defp cleanup_graph_before_delete(chunk_ids, document, repo, opts) do
    if sweeping?(document, opts) and ecto_graph_store?(opts) do
      graph_opts =
        opts
        |> Keyword.put(:repo, repo)
        |> Keyword.put(:collection_id, document.collection_id)

      GraphStore.delete_by_chunks(chunk_ids, graph_opts)
    else
      :ok
    end
  end

  defp cleanup_graph_after_delete(_chunk_ids, _document, _repo, _opts), do: :ok

  # :sweep_failed is for a store that *returns* an error. One that raises is
  # deliberately not folded into it: the exception happens inside the write
  # lock's own nested transaction, so DBConnection has already marked the
  # connection aborted by the time anything here could catch it, and rescuing
  # at this depth only turned the error into a MatchError on with_write_lock's
  # `{:ok, result} =`. Left to propagate, the outer rescue reports it as the
  # database error it is, with the transaction rolled back and the document
  # intact. Documented on delete/2 rather than papered over.
  defp sweep(document, repo, opts) do
    case GraphStore.maybe_sweep_orphans(document.collection_id, repo, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sweep_failed, reason}}
    end
  end
end
