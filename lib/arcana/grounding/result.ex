defmodule Arcana.Grounding.Result do
  @moduledoc """
  Result of grounding analysis on an LLM-generated answer.

  Contains information about how well the answer is supported by the
  retrieved context, including a faithfulness score and any detected
  hallucinated or faithful spans.

  ## Fields

  - `:score` - Average consistency score across sentences (0.0 to 1.0, higher is better),
    weighted by sentence length.
  - `:hallucinated_spans` - List of sentence-level span maps identifying unsupported parts
    of the answer. Each span has `:text`, `:start`, `:end` (byte offsets), `:score`
    (hallucination confidence), and `:sources` (list of `%{chunk_id: term(), score: float()}`
    sorted by overlap score desc).
  - `:faithful_spans` - List of sentence-level span maps identifying supported parts
    of the answer. Same shape as hallucinated spans.
  - `:token_labels` - Unused (kept for backwards compatibility). Always nil.
  """

  @type span :: %{
          text: String.t(),
          start: non_neg_integer(),
          end: non_neg_integer(),
          score: float(),
          sources: [%{chunk_id: term(), score: float()}]
        }

  @type t :: %__MODULE__{
          score: float(),
          hallucinated_spans: [span()],
          faithful_spans: [span()],
          token_labels: [map()] | nil
        }

  defstruct [:score, hallucinated_spans: [], faithful_spans: [], token_labels: nil]
end
