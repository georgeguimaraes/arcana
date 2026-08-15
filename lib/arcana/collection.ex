defmodule Arcana.Collection do
  @moduledoc """
  Represents a collection of documents for segmentation.

  Collections allow you to organize documents by product, country,
  or any other grouping criteria. Documents can be filtered by
  collection when searching.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "arcana_collections" do
    field(:name, :string)
    field(:description, :string)

    has_many(:documents, Arcana.Document)

    timestamps()
  end

  @doc false
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end

  @doc """
  Gets an existing collection by name or creates a new one.

  If a description is provided and the collection already exists,
  the description is updated only if the existing one is nil or empty.

  ## Examples

      {:ok, collection} = Collection.get_or_create("products", MyRepo)
      {:ok, collection} = Collection.get_or_create("default", MyRepo)
      {:ok, collection} = Collection.get_or_create("docs", MyRepo, "Official documentation")

  """
  def get_or_create(name, repo, description \\ nil) when is_binary(name) do
    case repo.get_by(__MODULE__, name: name) do
      nil ->
        %__MODULE__{}
        |> changeset(%{name: name, description: description})
        |> repo.insert()

      collection ->
        maybe_update_description(collection, description, repo)
    end
  end

  defp maybe_update_description(collection, nil, _repo), do: {:ok, collection}
  defp maybe_update_description(collection, "", _repo), do: {:ok, collection}

  defp maybe_update_description(collection, description, repo) do
    if is_nil(collection.description) or collection.description == "" do
      collection
      |> changeset(%{description: description})
      |> repo.update()
    else
      {:ok, collection}
    end
  end

  @doc """
  Fetches a collection by name.

  Returns `{:ok, collection}` or `{:error, {:unknown_collection, name}}`.
  """
  def fetch(name, repo) when is_binary(name) do
    case repo.get_by(__MODULE__, name: name) do
      nil -> {:error, {:unknown_collection, name}}
      collection -> {:ok, collection}
    end
  end

  @doc """
  Resolves a list of collection names to their IDs.

  Returns `{:ok, nil}` for unscoped queries (when collections is `[nil]`),
  otherwise `{:ok, ids}`. Unknown names are dropped, so the list can be
  empty — callers must treat an empty list as "match nothing", never as
  "no filter". With `strict: true`, the first unknown name returns
  `{:error, {:unknown_collection, name}}` instead.
  """
  def resolve_ids(names, repo, opts \\ [])

  def resolve_ids([nil], _repo, _opts), do: {:ok, nil}

  def resolve_ids(names, repo, opts) when is_list(names) do
    strict? = Keyword.get(opts, :strict, false)

    names
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case resolve_id(name, repo, strict?) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  @doc """
  Resolves a single collection name to its ID.

  Returns `{:ok, nil}` when `name` is `nil` (unscoped) or, in non-strict
  mode, when the collection doesn't exist. With `strict?` set, an unknown
  name returns `{:error, {:unknown_collection, name}}`.
  """
  def resolve_id(name, repo, strict? \\ false)

  def resolve_id(nil, _repo, _strict?), do: {:ok, nil}

  def resolve_id(name, repo, strict?) when is_binary(name) do
    case repo.get_by(__MODULE__, name: name) do
      nil when strict? -> {:error, {:unknown_collection, name}}
      nil -> {:ok, nil}
      collection -> {:ok, collection.id}
    end
  end

  @doc """
  Extracts collection names from search/ask opts.

  Looks for `:collections` (list) or `:collection` (single name).
  Returns `[nil]` if neither is set.
  """
  def names_from_opts(opts) do
    cond do
      Keyword.has_key?(opts, :collections) -> Keyword.get(opts, :collections)
      Keyword.has_key?(opts, :collection) -> [Keyword.get(opts, :collection)]
      true -> [nil]
    end
  end
end
