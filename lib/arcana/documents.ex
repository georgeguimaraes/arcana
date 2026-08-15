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

  alias Arcana.Document

  @doc """
  Lists documents, newest first.

  ## Options

    * `:repo` - The Ecto repo to use (required unless configured globally)
    * `:collection` - Filter by collection name. A name that doesn't
      exist matches nothing.
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

  ## Examples

      {:ok, document} = Arcana.get_document(id, repo: MyApp.Repo)

  """
  def get_document(id, opts) do
    repo = require_repo!(opts)

    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Document{} = document <-
           repo.one(from(d in Document, where: d.id == ^uuid, preload: [:collection])) do
      {:ok, document}
    else
      # Malformed ids can't match anything, same outcome as a missing row
      _ -> {:error, :not_found}
    end
  end

  defp base_query(opts) do
    Document
    |> filter_collection(Keyword.get(opts, :collection))
    |> filter_status(Keyword.get(opts, :status))
    |> filter_source_id(Keyword.get(opts, :source_id))
  end

  defp filter_collection(query, nil), do: query

  defp filter_collection(query, collection_name) do
    from(d in query,
      join: c in assoc(d, :collection),
      where: c.name == ^collection_name
    )
  end

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: from(d in query, where: d.status == ^status)

  defp filter_source_id(query, nil), do: query
  defp filter_source_id(query, source_id), do: from(d in query, where: d.source_id == ^source_id)

  defp require_repo!(opts), do: Arcana.Config.require_repo!(opts)

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
