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
end
