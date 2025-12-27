# Agentic RAG Design

## Overview

Add pipeline-based agentic RAG to Arcana. Users compose steps via pipes, with a context struct flowing through each transformation.

```elixir
Arcana.Agent.new(question, repo: MyRepo, llm: llm_fn)
|> Arcana.Agent.route(collections: ["docs", "support", "api"])
|> Arcana.Agent.decompose()
|> Arcana.Agent.search(self_correct: true)
|> Arcana.Agent.answer()
```

## Goals

1. **Self-correcting search** - Evaluate results, re-search if insufficient
2. **Multi-step retrieval** - Break complex questions into sub-questions
3. **Multi-collection routing** - Route questions to appropriate collections

## Non-Goals

- Generic agent/tool framework (use LangChain for that)
- Streaming responses (future work)
- Async/parallel sub-question execution (future work)

## Architecture

### Context Struct

```elixir
defmodule Arcana.Agent.Context do
  defstruct [
    # Input
    :question,
    :repo,
    :llm,

    # Options
    :limit,
    :threshold,

    # Populated by route/2
    :collections,
    :routing_reasoning,

    # Populated by decompose/1
    :sub_questions,

    # Populated by search/2
    :results,          # list of %{question: _, chunks: _, iterations: _}

    # Populated by answer/1
    :answer,
    :context_used
  ]
end
```

### Pipeline Steps

#### `new/2` - Initialize context

```elixir
def new(question, opts) do
  %Context{
    question: question,
    repo: Keyword.fetch!(opts, :repo),
    llm: Keyword.fetch!(opts, :llm),
    limit: Keyword.get(opts, :limit, 5),
    threshold: Keyword.get(opts, :threshold, 0.5)
  }
end
```

#### `route/2` - Collection routing

Asks LLM which collection(s) are relevant for the question.

```elixir
def route(ctx, opts) do
  collections = Keyword.fetch!(opts, :collections)

  prompt = """
  Given these collections: #{inspect(collections)}

  Which collection(s) should be searched for: "#{ctx.question}"

  Return JSON: {"collections": ["name1", "name2"], "reasoning": "..."}
  """

  {:ok, response} = ctx.llm.(prompt)
  parsed = Jason.decode!(response)

  %{ctx |
    collections: parsed["collections"],
    routing_reasoning: parsed["reasoning"]
  }
end
```

**Options:**
- `collections` (required) - list of collection names to choose from

#### `decompose/1` - Question decomposition

Breaks complex questions into sub-questions.

```elixir
def decompose(ctx) do
  prompt = """
  Break this question into simpler sub-questions that can be answered independently:

  "#{ctx.question}"

  Return JSON: {"sub_questions": ["q1", "q2"], "reasoning": "..."}
  If the question is already simple, return: {"sub_questions": ["#{ctx.question}"], "reasoning": "simple question"}
  """

  {:ok, response} = ctx.llm.(prompt)
  parsed = Jason.decode!(response)

  %{ctx | sub_questions: parsed["sub_questions"]}
end
```

#### `search/2` - Execute search with optional self-correction

```elixir
def search(ctx, opts \\ []) do
  self_correct = Keyword.get(opts, :self_correct, false)
  max_iterations = Keyword.get(opts, :max_iterations, 3)

  questions = ctx.sub_questions || [ctx.question]
  collections = ctx.collections || ["default"]

  results =
    for question <- questions,
        collection <- collections do
      chunks = do_search(ctx, question, collection, self_correct, max_iterations)
      %{question: question, collection: collection, chunks: chunks}
    end

  %{ctx | results: results}
end

defp do_search(ctx, question, collection, false, _max) do
  Arcana.search(question,
    repo: ctx.repo,
    collection: collection,
    limit: ctx.limit,
    threshold: ctx.threshold
  )
end

defp do_search(ctx, question, collection, true, max_iterations) do
  do_self_correcting_search(ctx, question, collection, max_iterations, 1)
end

defp do_self_correcting_search(ctx, question, collection, max, iteration) when iteration > max do
  # Give up, return best effort
  Arcana.search(question, repo: ctx.repo, collection: collection, limit: ctx.limit)
end

defp do_self_correcting_search(ctx, question, collection, max, iteration) do
  chunks = Arcana.search(question,
    repo: ctx.repo,
    collection: collection,
    limit: ctx.limit,
    threshold: ctx.threshold
  )

  if sufficient_results?(ctx, question, chunks) do
    chunks
  else
    # Rewrite query and try again
    {:ok, rewritten} = rewrite_for_better_results(ctx, question, chunks)
    do_self_correcting_search(ctx, rewritten, collection, max, iteration + 1)
  end
end

defp sufficient_results?(ctx, question, chunks) do
  prompt = """
  Question: "#{question}"

  Retrieved chunks:
  #{format_chunks(chunks)}

  Are these chunks sufficient to answer the question? Return JSON: {"sufficient": true/false, "reasoning": "..."}
  """

  {:ok, response} = ctx.llm.(prompt)
  Jason.decode!(response)["sufficient"]
end
```

**Options:**
- `self_correct` - enable self-correcting search (default: false)
- `max_iterations` - max retry attempts (default: 3)

#### `answer/1` - Generate final answer

```elixir
def answer(ctx) do
  all_chunks = ctx.results |> Enum.flat_map(& &1.chunks) |> Enum.uniq_by(& &1.id)

  prompt = """
  Question: "#{ctx.question}"

  Context:
  #{format_chunks(all_chunks)}

  Answer the question based on the context provided.
  """

  {:ok, answer} = ctx.llm.(prompt)

  %{ctx | answer: answer, context_used: all_chunks}
end
```

## Usage Examples

### Simple self-correcting search

```elixir
Arcana.Agent.new("What are the pricing tiers?", repo: MyRepo, llm: llm_fn)
|> Arcana.Agent.search(self_correct: true)
|> Arcana.Agent.answer()
```

### Full pipeline

```elixir
Arcana.Agent.new("Compare support response times across plans", repo: MyRepo, llm: llm_fn)
|> Arcana.Agent.route(collections: ["pricing", "support", "docs"])
|> Arcana.Agent.decompose()
|> Arcana.Agent.search(self_correct: true, max_iterations: 2)
|> Arcana.Agent.answer()
```

### Partial pipeline - just routing

```elixir
ctx = Arcana.Agent.new(question, repo: MyRepo, llm: llm_fn)
      |> Arcana.Agent.route(collections: ["a", "b", "c"])

# Use routing decision with regular search
Arcana.search(question, repo: MyRepo, collection: hd(ctx.collections))
```

## Telemetry Events

Each step emits telemetry:

- `[:arcana, :agent, :route, :start | :stop | :exception]`
- `[:arcana, :agent, :decompose, :start | :stop | :exception]`
- `[:arcana, :agent, :search, :start | :stop | :exception]`
- `[:arcana, :agent, :answer, :start | :stop | :exception]`

Stop metadata includes:
- `route`: `%{collections: [...], reasoning: "..."}`
- `decompose`: `%{sub_question_count: n}`
- `search`: `%{result_count: n, iterations: n}` (iterations for self-correct)
- `answer`: `%{context_chunk_count: n}`

## Error Handling

Each step returns the context on success. On LLM errors:

```elixir
def route(ctx, opts) do
  case do_route(ctx, opts) do
    {:ok, updated_ctx} -> updated_ctx
    {:error, reason} -> %{ctx | error: reason}
  end
end
```

Subsequent steps check for errors:

```elixir
def search(%{error: _} = ctx, _opts), do: ctx
def search(ctx, opts) do
  # ... normal processing
end
```

Users can check `ctx.error` at the end.

## Implementation Plan

### Phase 1: Core context and search
1. Create `Arcana.Agent.Context` struct
2. Implement `new/2`
3. Implement `search/2` without self-correction
4. Implement `answer/1`
5. Add telemetry

### Phase 2: Self-correcting search
1. Add `sufficient_results?/3` evaluation
2. Add query rewriting on insufficient results
3. Implement retry loop with max iterations
4. Add iteration count to telemetry

### Phase 3: Decompose
1. Implement `decompose/1` with LLM
2. Update `search/2` to handle multiple sub-questions
3. Update `answer/1` to synthesize from multiple sub-answers

### Phase 4: Router
1. Implement `route/2` with LLM
2. Update `search/2` to handle multiple collections
3. Add routing reasoning to context

## Testing Strategy

- Unit tests for each step with mock LLM
- Integration tests with real embeddings, mock LLM
- Property tests for context transformations
- Telemetry tests for all events
