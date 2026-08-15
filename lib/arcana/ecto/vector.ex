defmodule Arcana.Ecto.Vector do
  @moduledoc """
  Drop-in wrapper around `Pgvector.Ecto.Vector` with a real `equal?/2`.

  `Pgvector.Ecto.Vector` inherits Ecto's default `equal?/2` (plain `==`),
  so change detection compares terms structurally. Whenever the value
  loaded from the database isn't the exact representation being written
  back — a custom Postgrex types module decoding to a different struct,
  or list-vs-`%Pgvector{}` round trips — a byte-identical embedding
  always dirties the changeset, turning idempotent re-stores into write
  amplification plus HNSW index churn.

  This type delegates `type/cast/load/dump` to `Pgvector.Ecto.Vector`
  (identical wire behavior) and compares values by their encoded binary,
  so byte-identical vectors are equal regardless of representation.

  Values it can't encode (an opaque struct from a custom decoder that is
  neither enumerable nor castable) fall back to structural comparison,
  which is today's behavior rather than a crash.

  If pgvector-elixir ships `equal?/2` upstream (pgvector-python's
  `Vector.__eq__` is the family precedent), this module becomes a no-op
  layer that can be dropped in a major release.
  """

  use Ecto.Type

  alias Pgvector.Ecto.Vector, as: PgvectorVector

  def type, do: PgvectorVector.type()

  defdelegate cast(value), to: PgvectorVector
  defdelegate load(data), to: PgvectorVector
  defdelegate dump(value), to: PgvectorVector

  def equal?(a, b), do: normalize(a) == normalize(b)

  # Reduce every representation we can recognize to the encoded binary:
  # %Pgvector{} structs, lists, Nx tensors (via Pgvector.new/1), and any
  # other enumerable vector-like struct a custom Postgrex types module
  # might decode into.
  defp normalize(nil), do: nil
  defp normalize(%Pgvector{} = vector), do: Pgvector.to_binary(vector)

  defp normalize(value) when is_list(value) do
    encode(value, value)
  end

  defp normalize(value) when is_struct(value) do
    case Enumerable.impl_for(value) do
      nil -> encode(value, value)
      _ -> encode(Enum.to_list(value), value)
    end
  end

  defp normalize(value), do: value

  # Falls back to the original term when the value can't be encoded, so
  # comparison degrades to structural equality instead of raising.
  defp encode(value, original) do
    case PgvectorVector.cast(value) do
      {:ok, %Pgvector{} = vector} -> Pgvector.to_binary(vector)
      _ -> original
    end
  rescue
    # Pgvector.new/1 raises on anything it can't build a vector from
    _ -> original
  end
end
