# Evaluation

Measure and improve your retrieval quality with Arcana's evaluation system.

## Overview

Arcana provides tools to evaluate how well your RAG pipeline retrieves relevant information:

1. **Test Cases** - Questions paired with their known relevant chunks
2. **Evaluation Runs** - Execute searches and measure performance
3. **Metrics** - Standard IR metrics (MRR, Precision, Recall, Hit Rate)

## Creating Test Cases

### Manual Test Cases

Create test cases when you know which chunks should be retrieved for a question:

```elixir
# First, find the chunk you want to use as ground truth
chunks = Arcana.search("GenServer state", repo: MyApp.Repo, limit: 1)
chunk = hd(chunks)

# Create a test case linking question to relevant chunk
{:ok, test_case} = Arcana.Evaluation.create_test_case(
  repo: MyApp.Repo,
  question: "How do you manage state in Elixir?",
  relevant_chunk_ids: [chunk.id]
)
```

### Synthetic Test Cases

Generate test cases automatically using an LLM:

```elixir
{:ok, test_cases} = Arcana.Evaluation.generate_test_cases(
  repo: MyApp.Repo,
  llm: Application.get_env(:arcana, :llm),
  sample_size: 50
)
```

The generator samples random chunks and asks the LLM to create questions that should retrieve those chunks.

#### Filtering by Collection

Generate test cases from a specific collection:

```elixir
{:ok, test_cases} = Arcana.Evaluation.generate_test_cases(
  repo: MyApp.Repo,
  llm: Application.get_env(:arcana, :llm),
  sample_size: 50,
  collection: "elixir-docs"
)
```

#### Using the Mix Task

```bash
# Generate 50 test cases (default)
mix arcana.eval.generate

# Custom sample size
mix arcana.eval.generate --sample-size 100

# From a specific collection
mix arcana.eval.generate --collection elixir-docs

# From a specific source
mix arcana.eval.generate --source-id my-source
```

## Running Evaluations

Run an evaluation against all test cases:

```elixir
{:ok, run} = Arcana.Evaluation.run(
  repo: MyApp.Repo,
  mode: :semantic  # or :fulltext, :hybrid
)
```

### Evaluating Answer Quality

For end-to-end RAG evaluation, you can also evaluate the quality of generated answers:

```elixir
{:ok, run} = Arcana.Evaluation.run(
  repo: MyApp.Repo,
  mode: :semantic,
  evaluate_answers: true,
  llm: Application.get_env(:arcana, :llm)
)

# Includes faithfulness metric
run.metrics.faithfulness  # => 7.8 (0-10 scale)
```

When `evaluate_answers: true` is set, the evaluation:
1. Generates an answer for each test case using the retrieved chunks
2. Uses LLM-as-judge to score how faithful the answer is to the context
3. Aggregates scores into an overall faithfulness metric

**Faithfulness** measures whether the generated answer is grounded in the retrieved chunks (0 = hallucinated, 10 = fully faithful).

### Using the Mix Task

```bash
# Run with semantic search (default)
mix arcana.eval.run

# Run with hybrid search
mix arcana.eval.run --mode hybrid

# Run with full-text search
mix arcana.eval.run --mode fulltext
```

### Understanding Results

```elixir
# Overall metrics
run.metrics
# => %{
#   recall_at_1: 0.62,
#   recall_at_3: 0.78,
#   recall_at_5: 0.84,
#   recall_at_10: 0.91,
#   precision_at_1: 0.62,
#   precision_at_3: 0.52,
#   precision_at_5: 0.34,
#   precision_at_10: 0.18,
#   mrr: 0.76,
#   hit_rate_at_1: 0.62,
#   hit_rate_at_3: 0.78,
#   hit_rate_at_5: 0.84,
#   hit_rate_at_10: 0.91
# }

# Per-case results
run.results
# => %{"case-id" => %{hit: true, rank: 2, ...}, ...}

# Configuration used
run.config
# => %{mode: :semantic, embedding: %{model: "...", dimensions: 384}}
```

## Comparing Configurations

Run evaluations with different settings to find the best configuration:

```elixir
# Test semantic search
{:ok, semantic_run} = Arcana.Evaluation.run(repo: MyApp.Repo, mode: :semantic)

# Test hybrid search
{:ok, hybrid_run} = Arcana.Evaluation.run(repo: MyApp.Repo, mode: :hybrid)

# Compare
IO.puts("Semantic MRR: #{semantic_run.metrics.mrr}")
IO.puts("Hybrid MRR: #{hybrid_run.metrics.mrr}")
```

## Managing Test Cases and Runs

```elixir
# List all test cases
test_cases = Arcana.Evaluation.list_test_cases(repo: MyApp.Repo)

# Get a specific test case
test_case = Arcana.Evaluation.get_test_case(id, repo: MyApp.Repo)

# Delete a test case
{:ok, _} = Arcana.Evaluation.delete_test_case(id, repo: MyApp.Repo)

# List past runs
runs = Arcana.Evaluation.list_runs(repo: MyApp.Repo, limit: 10)

# Delete a run
{:ok, _} = Arcana.Evaluation.delete_run(run_id, repo: MyApp.Repo)
```

## Dashboard

The Arcana Dashboard provides a visual interface for evaluation:

- **Test Cases tab** - View, generate, and delete test cases
- **Run Evaluation tab** - Execute evaluations with different search modes
- **History tab** - View past runs with metrics

See the [Dashboard Guide](dashboard.md) for setup instructions.

## Metrics Explained

### Retrieval Metrics

| Metric | Description | Good Value |
|--------|-------------|------------|
| **MRR** (Mean Reciprocal Rank) | Average of 1/rank for first relevant result | > 0.7 |
| **Recall@K** | Fraction of relevant chunks found in top K | > 0.8 |
| **Precision@K** | Fraction of top K results that are relevant | > 0.6 |
| **Hit Rate@K** | Fraction of queries with at least one relevant result in top K | > 0.9 |

### Answer Quality Metrics

| Metric | Description | Good Value |
|--------|-------------|------------|
| **Faithfulness** | How well the answer is grounded in retrieved context (0-10) | > 7.0 |

### Which Metric to Focus On?

- **MRR** - Best for single-answer scenarios where you need the relevant chunk first
- **Recall@K** - Important when you need to find all relevant information
- **Precision@K** - Matters when you want to minimize irrelevant context
- **Hit Rate@K** - Good baseline to ensure retrieval is working at all
- **Faithfulness** - Essential for preventing hallucinations in generated answers

## Best Practices

1. **Diverse test cases** - Cover different topics and question types
2. **Sufficient sample size** - Aim for 50+ test cases for reliable metrics
3. **Regular evaluation** - Re-run after changing embeddings, chunking, or search settings
4. **Track over time** - Compare runs to ensure changes improve quality
5. **Use collection filtering** - Evaluate specific document collections separately
6. **Test all search modes** - Compare semantic, fulltext, and hybrid to find what works best
