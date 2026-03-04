defmodule Arcana.Grounding.InputFormatter do
  @moduledoc """
  Formats context for grounding analysis.

  Joins chunk texts into a single premise string for NLI scoring.
  """

  @doc """
  Joins context passages into a single string for use as the NLI premise.

  ## Examples

      iex> chunks = [%{text: "Elixir is functional."}, %{text: "It runs on BEAM."}]
      iex> Arcana.Grounding.InputFormatter.format("What is Elixir?", chunks)
      "Elixir is functional.\\nIt runs on BEAM."
  """
  def format(_question, chunks) do
    Enum.map_join(chunks, "\n", & &1.text)
  end
end
