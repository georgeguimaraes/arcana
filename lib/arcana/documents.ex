defmodule Arcana.Documents do
  @moduledoc """
  Public read API for documents.

  Lets host apps build admin surfaces (list a collection's documents,
  show ingestion status, paginate) and assert on ingestion outcomes in
  tests without querying Arcana's schemas through Ecto directly.

  `Arcana.Document` is the stable public shape: `id`, `status`,
  `chunk_count`, `metadata`, `source_id`, `content_type`, timestamps,
  and the preloaded `collection`.
  """

  import Ecto.Query

  alias Arcana.{CollectionScope, Document, DocumentMetadata, RetrievalScope}

  @doc """
  Lists documents, newest first.

  ## Options

    * `:repo` - The Ecto repo to use (required unless configured globally)
    * `:collection` - Filter by `:all`, one collection name, a list of names,
      or `[]` to match nothing. Unknown names never widen the query.
    * `:status` - Filter by status (`:pending`, `:processing`,
      `:completed`, `:failed`)
    * `:source_id` - Filter by source id
    * `:limit` - Maximum documents to return (default: 50)
    * `:offset` - Number of documents to skip (default: 0)

  ## Examples

      {:ok, docs} = Arcana.list_documents(repo: MyApp.Repo, collection: "products")
      {:ok, failed} = Arcana.list_documents(repo: MyApp.Repo, status: :failed)
      {:ok, page2} = Arcana.list_documents(repo: MyApp.Repo, limit: 20, offset: 20)

  """
  def list_documents(opts) do
    repo = require_repo!(opts)
    limit = validate_non_neg_integer!(opts, :limit, 50)
    offset = validate_non_neg_integer!(opts, :offset, 0)

    documents =
      opts
      |> base_query()
      |> order_by([d], desc: d.inserted_at, desc: d.id)
      |> limit(^limit)
      |> offset(^offset)
      |> preload([:collection])
      |> repo.all()

    {:ok, documents}
  end

  @doc """
  Counts documents matching the same filters as `list_documents/1`
  (`:collection`, `:status`, `:source_id`), for building pagination.

  ## Examples

      {:ok, total} = Arcana.count_documents(repo: MyApp.Repo, collection: "products")

  """
  def count_documents(opts) do
    repo = require_repo!(opts)

    {:ok, opts |> base_query() |> repo.aggregate(:count)}
  end

  @doc """
  Fetches a single document by id, with its collection preloaded.

  Returns `{:ok, document}` or `{:error, :not_found}`.

  ## Options

    * `:repo` - The Ecto repo to use (required unless configured globally)
    * `:collection` - Limit the lookup to `:all`, one collection name, a list
      of names, or `[]` to match nothing

  ## Examples

      {:ok, document} = Arcana.get_document(id, repo: MyApp.Repo)
      {:ok, document} =
        Arcana.get_document(id, repo: MyApp.Repo, collection: ["support", "api"])

  """
  def get_document(id, opts) do
    repo = require_repo!(opts)
    collection_scope = CollectionScope.from_opts!(opts, :all)

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Document{} = document <-
           Document
           |> apply_collection_scope(collection_scope)
           |> where([d], d.id == ^uuid)
           |> preload([:collection])
           |> repo.one() do
      {:ok, document}
    else
      # Malformed ids can't match anything, same outcome as a missing row
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Fetches sparse metadata for several published documents in one query.

  A collection scope is required. Pass `collection: "support"`,
  `collection: ["support", "api"]`, or an explicit `collection: :all`.
  Missing IDs, documents outside the scope, and documents that have not
  completed ingestion are omitted from the returned ID-keyed map. Duplicate
  IDs are queried once.

  Returns `{:error, {:invalid_document_id, id}}` without querying when any ID
  is not a valid UUID.

  ## Options

    * `:repo` - The Ecto repo to use (required unless configured globally)
    * `:collection` - `:all`, one collection name, a list of names, or `[]`

  """
  @spec get_document_metadata([Ecto.UUID.t()], keyword()) ::
          {:ok, %{optional(Ecto.UUID.t()) => DocumentMetadata.t()}}
          | {:error, {:invalid_document_id, term()}}
  def get_document_metadata(ids, opts) when is_list(ids) do
    repo = require_repo!(opts)
    collection_scope = CollectionScope.from_opts!(opts, :all)
    require_collection_scope!(opts)

    with {:ok, ids} <- cast_document_ids(ids) do
      fetch_document_metadata(ids, collection_scope, repo)
    end
  end

  def get_document_metadata(ids, _opts) do
    raise ArgumentError, ":document_ids must be a list, got: #{inspect(ids)}"
  end

  defp base_query(opts) do
    collection_scope = CollectionScope.from_opts!(opts, :all)

    Document
    |> apply_collection_scope(collection_scope)
    |> filter_status(Keyword.get(opts, :status))
    |> filter_source_id(Keyword.get(opts, :source_id))
  end

  defp apply_collection_scope(query, :all), do: query
  defp apply_collection_scope(query, {:only, []}), do: from(d in query, where: false)

  defp apply_collection_scope(query, {:only, collection_names}) do
    from(d in query,
      join: c in assoc(d, :collection),
      where: c.name in ^collection_names
    )
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(d in query, where: d.status == ^status)

  defp filter_source_id(query, nil), do: query
  defp filter_source_id(query, source_id), do: from(d in query, where: d.source_id == ^source_id)

  defp require_repo!(opts), do: Arcana.Config.require_repo!(opts)

  defp fetch_document_metadata([], _collection_scope, _repo), do: {:ok, %{}}

  defp fetch_document_metadata(ids, collection_scope, repo) do
    metadata =
      RetrievalScope.documents()
      |> apply_collection_scope(collection_scope)
      |> where([document: d], d.id in ^ids)
      |> select([document: d], %{id: d.id, source_id: d.source_id, metadata: d.metadata})
      |> repo.all()
      |> Map.new(fn attributes ->
        document = struct!(DocumentMetadata, attributes)
        {document.id, document}
      end)

    {:ok, metadata}
  end

  defp require_collection_scope!(opts) do
    unless Keyword.has_key?(opts, :collection) do
      raise ArgumentError,
            "get_document_metadata/2 requires an explicit :collection scope"
    end
  end

  defp cast_document_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, cast_ids} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, [uuid | cast_ids]}}
        :error -> {:halt, {:error, {:invalid_document_id, id}}}
      end
    end)
    |> case do
      {:ok, cast_ids} -> {:ok, cast_ids |> Enum.reverse() |> Enum.uniq()}
      {:error, _reason} = error -> error
    end
  end

  defp validate_non_neg_integer!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 ->
        value

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer, got: #{inspect(other)}"
    end
  end
end
