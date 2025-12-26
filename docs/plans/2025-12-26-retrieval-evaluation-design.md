# Retrieval Evaluation Design

## Overview

Add synthetic test case generation and retrieval evaluation to Arcana, allowing users to measure search quality and track improvements over time.

## Decisions

1. **Scope**: Retrieval only (not full RAG pipeline)
2. **Question generation**: Use existing `Arcana.LLM` protocol
3. **Persistence**: Database tables for test cases and runs
4. **Triggers**: API function + Dashboard + Mix task
5. **Metrics**: Recall@K, Precision@K, MRR + per-question breakdown
6. **K values**: Fixed set [1, 3, 5, 10]
7. **Dataset management**: Both generate new and evaluate existing

## Data Model

```elixir
# TestCase - a question with expected chunks
defmodule Arcana.Evaluation.TestCase do
  schema "arcana_evaluation_test_cases" do
    field :question, :string
    field :source, Ecto.Enum, values: [:synthetic, :manual]
    belongs_to :source_chunk, Arcana.Chunk
    many_to_many :relevant_chunks, Arcana.Chunk,
      join_through: "arcana_evaluation_test_case_chunks"
    timestamps()
  end
end

# EvaluationRun - results of running evaluation
defmodule Arcana.Evaluation.Run do
  schema "arcana_evaluation_runs" do
    field :status, Ecto.Enum, values: [:running, :completed, :failed]
    field :metrics, :map
    field :results, :map
    field :config, :map
    field :test_case_count, :integer
    timestamps()
  end
end
```

## Public API

```elixir
Arcana.Evaluation.generate_test_cases(repo: Repo, llm: llm, sample_size: 50)
Arcana.Evaluation.run(repo: Repo, mode: :semantic)
Arcana.Evaluation.list_runs(repo: Repo)
Arcana.Evaluation.get_run(run_id, repo: Repo)
```

## Mix Tasks

```bash
mix arcana.eval.generate --sample-size 50
mix arcana.eval.run --mode semantic
mix arcana.eval.run --generate --sample-size 50 --fail-under 0.8
```

## Dashboard

New "Evaluation" tab with three views:
- **Test Cases**: View, add, delete test cases
- **Run Evaluation**: Execute and see results with failure drill-down
- **History**: Compare runs over time

## Metrics

- Recall@K: fraction of relevant docs in top K
- Precision@K: fraction of top K that are relevant
- MRR: reciprocal rank of first relevant result
- Hit Rate@K: binary - did we find at least one relevant doc?
