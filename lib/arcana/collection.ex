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

  Accepts either a string name or the atom `:default` which
  maps to the "default" collection.

  ## Examples

      {:ok, collection} = Collection.get_or_create("products", MyRepo)
      {:ok, collection} = Collection.get_or_create(:default, MyRepo)

  """
  def get_or_create(:default, repo), do: get_or_create("default", repo)

  def get_or_create(name, repo) when is_binary(name) do
    case repo.get_by(__MODULE__, name: name) do
      nil ->
        %__MODULE__{}
        |> changeset(%{name: name})
        |> repo.insert()

      collection ->
        {:ok, collection}
    end
  end
end
