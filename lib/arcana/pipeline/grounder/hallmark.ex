defmodule Arcana.Pipeline.Grounder.Hallmark do
  @moduledoc """
  Default grounder using Hallmark (Vectara HHEM via Bumblebee).

  Hallmark scores each sentence in the answer against the combined context
  using natural language inference. Sentences below the threshold are marked
  as hallucinated.

  ## Requirements

  Requires the `hallmark` package:

      {:hallmark, "~> 1.0"}

  The model is downloaded automatically on first use via Bumblebee.

  ## Usage

      # As the default grounder (used automatically)
      ctx |> Pipeline.ground()

      # Explicitly
      ctx |> Pipeline.ground(grounder: Arcana.Pipeline.Grounder.Hallmark)
  """

  @behaviour Arcana.Pipeline.Grounder

  alias Arcana.Grounding

  @impl Arcana.Pipeline.Grounder
  def ground(answer, chunks, opts) do
    unless Code.ensure_loaded?(Hallmark) do
      raise """
      Hallmark is required for the default grounder.

      Add {:hallmark, "~> 1.0"} to your deps in mix.exs, or use a custom grounder:

          Pipeline.ground(ctx, grounder: fn answer, chunks, opts ->
            {:ok, %Arcana.Grounding.Result{score: 1.0, hallucinated_spans: []}}
          end)
      """
    end

    question = Keyword.fetch!(opts, :question)
    Grounding.HallmarkServing.run(question, chunks, answer, opts)
  end
end
