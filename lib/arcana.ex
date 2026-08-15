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

  Returns `:ok`, `{:error, :not_found}`, or `{:error, {:sweep_failed,
  reason}}` when the graph store fails to sweep. In the `:sweep_failed`
  case the document and its chunks ARE deleted — only the orphan cleanup
  failed, so the collection may hold entities with zero mentions until
  the next sweep.

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
        repo.delete!(document)

        case GraphStore.maybe_sweep_orphans(document.collection_id, repo, opts) do
          :ok -> :ok
          {:error, reason} -> {:error, {:sweep_failed, reason}}
        end
    end
  end
end
