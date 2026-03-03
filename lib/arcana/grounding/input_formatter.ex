defmodule Arcana.Grounding.InputFormatter do
  @moduledoc """
  Formats input for the LettuceDetect grounding model.

  LettuceDetect expects a specific prompt format: context passages joined by
  a separator token, followed by the question. This becomes the first segment
  in a pair encoding, with the answer as the second segment.

  ## Format

      <passage_1><passage_separator><passage_2>... Question: <question>

  This module only produces the first segment (context + question).
  The answer is passed separately as the second segment during tokenization.
  """

  @passage_separator "<passage_separator>"

  @doc """
  Formats context passages and question into the first segment for LettuceDetect.

  ## Examples

      iex> chunks = [%{text: "Elixir is functional."}, %{text: "It runs on BEAM."}]
      iex> Arcana.Grounding.InputFormatter.format("What is Elixir?", chunks)
      "Elixir is functional.<passage_separator>It runs on BEAM. Question: What is Elixir?"
  """
  def format(question, chunks) do
    context =
      chunks
      |> Enum.map(& &1.text)
      |> Enum.join(@passage_separator)

    "#{context} Question: #{question}"
  end
end
