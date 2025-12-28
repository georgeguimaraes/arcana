# End-to-End Answer Evaluation Design

## Overview

Extend `Evaluation.run/1` to evaluate answer quality, not just retrieval. When `evaluate_answers: true`, the system generates answers and judges their faithfulness to the retrieved context.

## API

```elixir
{:ok, run} = Evaluation.run(
  repo: MyApp.Repo,
  mode: :semantic,
  evaluate_answers: true,  # NEW
  llm: my_llm              # required when evaluate_answers: true
)

run.metrics
# => %{
#   # Existing retrieval metrics
#   mrr: 0.76,
#   recall_at_5: 0.84,
#   precision_at_5: 0.68,
#   hit_rate_at_5: 0.91,
#
#   # New answer metric
#   faithfulness: 7.8  # average score 0-10
# }

# Per-case results include answer evaluation
run.results["case-id"]
# => %{
#   # Existing
#   test_case_id: "...",
#   question: "...",
#   retrieved_chunk_ids: [...],
#   recall: %{...},
#
#   # New
#   answer: "Generated answer text...",
#   faithfulness_score: 8,
#   faithfulness_reasoning: "Answer is well-supported by context..."
# }
```

## Metric: Faithfulness

Faithfulness measures whether the generated answer is grounded in the retrieved chunks.

- **Scale**: 0-10
- **0**: Completely unfaithful, hallucinated, contradicts context
- **5**: Partially supported, some claims lack grounding
- **10**: Fully faithful, every claim supported by context

## Implementation

### New Module: `Arcana.Evaluation.AnswerMetrics`

```elixir
defmodule Arcana.Evaluation.AnswerMetrics do
  @moduledoc """
  Evaluates answer quality using LLM-as-judge.
  """

  @default_faithfulness_prompt """
  You are evaluating whether an answer is faithful to the provided context.

  Question: {question}

  Context (retrieved chunks):
  {chunks}

  Answer to evaluate:
  {answer}

  Rate the faithfulness on a scale of 0-10:
  - 0: Completely unfaithful, hallucinated, or contradicts the context
  - 5: Partially supported, some claims lack grounding
  - 10: Fully faithful, every claim is supported by the context

  Respond with JSON only:
  {"score": <0-10>, "reasoning": "<brief explanation>"}
  """

  def evaluate_faithfulness(question, chunks, answer, opts)
  def default_prompt(), do: @default_faithfulness_prompt
end
```

### Changes to `Evaluation.run/1`

1. Accept new options: `evaluate_answers`, `llm`, `faithfulness_prompt`
2. Validate `:llm` required when `evaluate_answers: true`
3. For each test case:
   - Search for chunks (existing)
   - Generate answer using `Arcana.ask/2`
   - Judge faithfulness with LLM
4. Store answer + scores in per-case results
5. Aggregate faithfulness scores into metrics

### Data Flow

```
Test Case
    ↓
Search (existing)
    ↓
Retrieved Chunks → Retrieval Metrics (existing)
    ↓
Generate Answer (Arcana.ask)
    ↓
Judge Faithfulness (LLM)
    ↓
Store: answer, faithfulness_score, faithfulness_reasoning
    ↓
Aggregate: average faithfulness score
```

## Schema Changes

None required. Existing `Run` schema stores `metrics` and `results` as maps.

## UI Changes (EvaluationLive)

### Run Evaluation Tab

Add checkbox to enable answer evaluation:

```
[ ] Evaluate Answers (requires LLM)
```

When checked, the run will include faithfulness scoring.

### History Tab

Show faithfulness metric alongside retrieval metrics:

```
┌─────────────────────────────────────────────────┐
│ Recall@5: 84%  Precision@5: 68%  MRR: 76%       │
│ Faithfulness: 7.8/10                            │  ← NEW
└─────────────────────────────────────────────────┘
```

### Per-Case Details (future)

Optionally expand a run to see individual case results with generated answers and reasoning.

## Future Extensions

- Additional metrics: Relevance, Completeness
- Reference answer comparison (correctness)
- Per-case drill-down in dashboard
