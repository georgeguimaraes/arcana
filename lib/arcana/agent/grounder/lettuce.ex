defmodule Arcana.Agent.Grounder.Lettuce do
  @moduledoc """
  Default grounder using LettuceDetect via ONNX Runtime.

  LettuceDetect (`KRLabsOrg/lettucedect-base-modernbert-en-v1`) is a ModernBERT-based
  token classifier that labels each token in the answer as faithful or hallucinated
  based on the provided context.

  ## Requirements

  Requires the `ortex` package for ONNX Runtime inference:

      {:ortex, "~> 0.1"}

  And a pre-exported ONNX model (see `scripts/export_lettuce_onnx.py`):

      config :arcana, Arcana.Grounding.Serving,
        model_path: "/path/to/lettucedect/model.onnx"

  ## Usage

      # As the default grounder (used automatically)
      ctx |> Agent.ground()

      # Explicitly
      ctx |> Agent.ground(grounder: Arcana.Agent.Grounder.Lettuce)
  """

  @behaviour Arcana.Agent.Grounder

  @impl Arcana.Agent.Grounder
  def ground(answer, chunks, opts) do
    unless Code.ensure_loaded?(Ortex) do
      raise """
      Ortex is required for the LettuceDetect grounder.

      Add {:ortex, "~> 0.1"} to your deps in mix.exs, or use a custom grounder:

          Agent.ground(ctx, grounder: fn answer, chunks, opts ->
            {:ok, %Arcana.Grounding.Result{score: 1.0, hallucinated_spans: []}}
          end)
      """
    end

    question = Keyword.fetch!(opts, :question)
    Arcana.Grounding.Serving.run(question, chunks, answer, opts)
  end
end
