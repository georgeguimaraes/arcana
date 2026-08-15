defmodule Arcana.Ecto.Vector do
  @moduledoc """
  Drop-in wrapper around `Pgvector.Ecto.Vector` with a real `equal?/2`.

  `Pgvector.Ecto.Vector` inherits Ecto's default `equal?/2` (plain `==`),
  so change detection compares terms structurally. Whenever the value
  loaded from the database isn't the exact same representation as the
  value being written back — a custom Postgrex types module decoding to
  a different struct, or list-vs-`%Pgvector{}` round trips — a
  byte-identical embedding always dirties the changeset, turning
  idempotent re-stores into write amplification plus HNSW index churn.

  This type delegates `type/cast/load/dump` to `Pgvector.Ecto.Vector`
  (identical wire behavior) and compares values by their encoded binary,
  so byte-identical vectors are equal regardless of representation.

  If pgvector-elixir ships `equal?/2` upstream (pgvector-python's
  `Vector.__eq__` is the family precedent), this module becomes a no-op
  layer that can be dropped in a major release.
  """

  use Ecto.Type

  def type, do: Pgvector.Ecto.Vector.type()

  defdelegate cast(value), to: Pgvector.Ecto.Vector
  defdelegate load(data), to: Pgvector.Ecto.Vector
  defdelegate dump(value), to: Pgvector.Ecto.Vector

  def equal?(a, b), do: normalize(a) == normalize(b)

  # Compare by encoded binary: lists, %Pgvector{} structs, and Nx tensors
  # all normalize through Pgvector.new/1. Values cast can't handle (e.g.
  # a custom types module's own struct) fall back to themselves, which
  # degrades to today's structural comparison rather than crashing.
  defp normalize(nil), do: nil
  defp normalize(%Pgvector{} = vector), do: Pgvector.to_binary(vector)

  defp normalize(value) do
    case Pgvector.Ecto.Vector.cast(value) do
      {:ok, %Pgvector{} = vector} -> Pgvector.to_binary(vector)
      _ -> value
    end
  rescue
    # Pgvector.new/1 raises on uncastable input (e.g. a string)
    _ -> value
  end
end
