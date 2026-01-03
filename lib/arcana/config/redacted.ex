defmodule Arcana.Config.Redacted do
  @moduledoc """
  Wrapper struct for config values that redacts sensitive data on inspect.

  Created via `Arcana.Config.redact/1`.
  """

  defstruct [:value]

  defimpl Inspect do
    def inspect(%{value: value}, opts) do
      Inspect.Algebra.to_doc(value, opts)
    end
  end
end
