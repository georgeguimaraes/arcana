defmodule Arcana.Test.UnloadedBinaryParser do
  @moduledoc """
  A binary-capable parser that exists only to be unloaded.

  `Arcana.FileParser.PDF.supports_binary?/1` has to load a module before
  asking what it exports, and proving that needs a module no other test
  touches: the check purges this one from the code server first, which
  would break anything referencing it concurrently.
  """

  @behaviour Arcana.FileParser

  @impl true
  def parse(_input, _opts), do: {:ok, "unloaded parser output"}

  @impl true
  def supports_binary?, do: true
end
