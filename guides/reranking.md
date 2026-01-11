# Re-ranking

Improve retrieval quality by re-scoring and filtering search results before answer generation.

## Overview

Re-ranking is a second-stage retrieval step that scores each chunk based on relevance to the question, filters by a threshold, and re-sorts by score. This improves answer quality by ensuring only the most relevant context reaches the LLM.

## Using Re-ranking in the Agent Pipeline

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, LangChain.chat(prompt)} end

ctx =
  Agent.new("What is Elixir?", repo: MyApp.Repo, llm: llm)
  |> Agent.search()
  |> Agent.rerank()      # Re-rank before answering
  |> Agent.answer()

ctx.answer
```

## Configuration

### Threshold

The threshold (0-10) filters out low-relevance chunks:

```elixir
# Keep only highly relevant chunks (score >= 8)
Agent.rerank(ctx, threshold: 8)

# More permissive (score >= 5)
Agent.rerank(ctx, threshold: 5)
```

Default threshold is 7.

### Custom Prompt

Customize how the LLM scores relevance:

```elixir
custom_prompt = fn question, chunk_text ->
  """
  Rate how relevant this text is for answering the question.

  Question: #{question}
  Text: #{chunk_text}

  Score 0-10 where 10 is perfectly relevant.
  Return JSON: {"score": <number>, "reasoning": "<brief explanation>"}
  """
end

Agent.rerank(ctx, prompt: custom_prompt)
```

## Custom Rerankers

### Implementing the Behaviour

Create a custom reranker by implementing `Arcana.Agent.Reranker`:

```elixir
defmodule MyApp.CrossEncoderReranker do
  @behaviour Arcana.Agent.Reranker

  @impl Arcana.Agent.Reranker
  def rerank(question, chunks, opts) do
    threshold = Keyword.get(opts, :threshold, 0.5)

    scored_chunks =
      chunks
      |> Enum.map(fn chunk ->
        score = cross_encoder_score(question, chunk.text)
        {chunk, score}
      end)
      |> Enum.filter(fn {_chunk, score} -> score >= threshold end)
      |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)
      |> Enum.map(fn {chunk, _score} -> chunk end)

    {:ok, scored_chunks}
  end

  defp cross_encoder_score(question, text) do
    # Call your cross-encoder model
    Nx.Serving.batched_run(MyApp.CrossEncoder, {question, text})
  end
end
```

Use it:

```elixir
Agent.rerank(ctx, reranker: MyApp.CrossEncoderReranker)
```

### Inline Function

For simple cases, pass a function directly:

```elixir
Agent.rerank(ctx, reranker: fn question, chunks, _opts ->
  # Your custom logic
  filtered = Enum.filter(chunks, &relevant?(&1, question))
  {:ok, filtered}
end)
```

## Built-in Rerankers

### Arcana.Agent.Reranker.LLM (Default)

Uses your LLM to score each chunk:

1. Prompts the LLM with question + chunk text
2. Parses a 0-10 score from the response
3. Filters chunks below threshold
4. Sorts by score descending

This is the default when you call `Arcana.Agent.rerank/2`.

### Arcana.Agent.Reranker.ColBERT

ColBERT-style neural reranking using per-token embeddings and MaxSim scoring. Provides more nuanced relevance scoring than single-vector methods by matching individual query tokens to document tokens.

Add the optional dependency:

```elixir
{:stephen, "~> 0.1"}
```

Use it:

```elixir
Agent.rerank(ctx, reranker: Arcana.Agent.Reranker.ColBERT)

# With options
Agent.rerank(ctx, reranker: {Arcana.Agent.Reranker.ColBERT, top_k: 5})
```

**Options:**

- `:encoder` - Pre-loaded Stephen encoder (loads default on first use if not provided)
- `:threshold` - Minimum score to keep (default: 0.0)
- `:top_k` - Maximum results to return

**When to use ColBERT:**

- When you need high-quality reranking without LLM latency/cost
- When semantic nuance matters (e.g., technical documentation)
- When you want deterministic, reproducible scores

**Trade-offs vs LLM reranker:**

| Aspect | ColBERT | LLM |
|--------|---------|-----|
| Latency | Fast (local inference) | Slow (API call per chunk) |
| Cost | Free after model load | Per-token API cost |
| Quality | Excellent for semantic similarity | Can understand complex relevance |
| Customization | Fixed model behavior | Custom prompts |

## Telemetry

Re-ranking emits telemetry events:

```elixir
:telemetry.attach(
  "rerank-logger",
  [:arcana, :agent, :rerank, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("Reranked: #{metadata.chunks_before} -> #{metadata.chunks_after} chunks")
  end,
  nil
)
```

## When to Use Re-ranking

Re-ranking is most valuable when:

- Your initial search returns many marginally relevant results
- Answer quality suffers from irrelevant context
- You have compute budget for the extra LLM calls (one per chunk)

Skip re-ranking when:

- Search already returns highly relevant results
- Latency is critical (adds one LLM call per chunk)
- You're using a very small result set (limit: 3 or less)
