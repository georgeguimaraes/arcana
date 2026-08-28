defmodule Arcana.CollectionScope do
  @moduledoc """
  Represents the collections included in a read.

  Public inputs are normalized before they reach query code:

    * `:all` includes every collection
    * a collection name includes only that collection
    * a list of names includes those collections
    * an empty list matches no collections

  Collection names must be non-empty binaries. Normalization preserves their
  order while removing duplicates.
  """

  @type name :: String.t()
  @type input :: :all | name() | [name()]
  @type t :: :all | {:only, [name()]}
  @type error_reason ::
          {:invalid_collection_scope, term()} | {:unsupported_collection_option, atom()}

  @doc """
  Normalizes a public collection scope.

  Returns `{:error, {:invalid_collection_scope, input}}` when a name is blank
  or an input has an unsupported shape.
  """
  @spec normalize(term()) :: {:ok, t()} | {:error, error_reason()}
  def normalize(:all), do: {:ok, :all}

  def normalize(name) when is_binary(name) do
    if valid_name?(name) do
      {:ok, {:only, [name]}}
    else
      invalid_scope(name)
    end
  end

  def normalize(names) when is_list(names) do
    if Enum.all?(names, &valid_name?/1) do
      {:ok, {:only, Enum.uniq(names)}}
    else
      invalid_scope(names)
    end
  end

  def normalize(input), do: invalid_scope(input)

  @doc """
  Normalizes a collection scope or raises `ArgumentError`.
  """
  @spec normalize!(term()) :: t()
  def normalize!(input) do
    case normalize(input) do
      {:ok, scope} -> scope
      {:error, reason} -> raise ArgumentError, error_message(reason)
    end
  end

  @doc """
  Reads a collection scope from keyword options.

  The `:collection` option accepts every public scope shape. When it is absent,
  `default` is normalized instead. The removed `:collections` alias is rejected
  so an outdated scoped caller cannot silently widen to the default.
  """
  @spec from_opts(keyword(), input()) :: {:ok, t()} | {:error, error_reason()}
  def from_opts(opts, default) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :collections) ->
        {:error, {:unsupported_collection_option, :collections}}

      Keyword.has_key?(opts, :collection) ->
        normalize(Keyword.fetch!(opts, :collection))

      true ->
        normalize(default)
    end
  end

  @doc """
  Reads and normalizes a collection scope from options or raises `ArgumentError`.
  """
  @spec from_opts!(keyword(), input()) :: t()
  def from_opts!(opts, default) do
    case from_opts(opts, default) do
      {:ok, scope} -> scope
      {:error, reason} -> raise ArgumentError, error_message(reason)
    end
  end

  @doc """
  Returns the intersection of two normalized collection scopes.

  When both scopes list names, their order follows the first scope.
  """
  @spec intersect(t(), t()) :: t()
  def intersect(:all, scope), do: scope
  def intersect(scope, :all), do: scope

  def intersect({:only, first}, {:only, second}) do
    included = MapSet.new(second)
    {:only, Enum.filter(first, &MapSet.member?(included, &1))}
  end

  @doc """
  Returns whether every collection in `scope` is included in `allowed`.

  This is useful at authorization boundaries where silently intersecting an
  explicit request would accept only part of a forged scope.
  """
  @spec subset?(t(), t()) :: boolean()
  def subset?(_scope, :all), do: true
  def subset?(:all, {:only, _allowed}), do: false

  def subset?({:only, names}, {:only, allowed}) do
    allowed = MapSet.new(allowed)
    Enum.all?(names, &MapSet.member?(allowed, &1))
  end

  defp valid_name?(name), do: is_binary(name) and String.trim(name) != ""

  defp invalid_scope(input), do: {:error, {:invalid_collection_scope, input}}

  defp error_message({:unsupported_collection_option, :collections}) do
    ":collections is not supported, pass the scope through :collection"
  end

  defp error_message({:invalid_collection_scope, input}) do
    "collection scope must be :all, a non-empty name, or a list of non-empty names, got: #{inspect(input)}"
  end
end
