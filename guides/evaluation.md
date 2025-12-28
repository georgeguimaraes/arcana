# Evaluation

Measure and improve your retrieval quality with Arcana's evaluation system.

## Overview

Arcana provides tools to evaluate how well your RAG pipeline retrieves relevant information:

1. **Test Cases** - Questions paired with their known relevant chunks
2. **Evaluation Runs** - Execute searches and measure performance
3. **Metrics** - Standard IR metrics (MRR, Precision, Recall)

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
llm = fn prompt ->
  # Your LLM implementation
  {:ok, LangChain.chat(prompt)}
end

{:ok, test_cases} = Arcana.Evaluation.generate_test_cases(
  repo: MyApp.Repo,
  llm: llm,
  sample_size: 50
)
```

The generator samples random chunks and asks the LLM to create questions that should retrieve those chunks.

## Running Evaluations

Run an evaluation against all test cases:

```elixir
{:ok, run} = Arcana.Evaluation.run(
  repo: MyApp.Repo,
  mode: :semantic  # or :fulltext, :hybrid
)
```

### Understanding Results

```elixir
# Overall metrics
run.metrics
# => %{
#   recall_at_5: 0.84,      # % of relevant chunks in top 5
#   precision_at_5: 0.68,   # % of top 5 that are relevant
#   mrr: 0.76               # Mean Reciprocal Rank
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

## Metrics Explained

| Metric | Description | Good Value |
|--------|-------------|------------|
| **MRR** (Mean Reciprocal Rank) | Average of 1/rank for first relevant result | > 0.7 |
| **Recall@K** | Fraction of relevant chunks found in top K | > 0.8 |
| **Precision@K** | Fraction of top K results that are relevant | > 0.6 |

## Best Practices

1. **Diverse test cases** - Cover different topics and question types
2. **Sufficient sample size** - Aim for 50+ test cases for reliable metrics
3. **Regular evaluation** - Re-run after changing embeddings, chunking, or search settings
4. **Track over time** - Compare runs to ensure changes improve quality
