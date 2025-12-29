# Agentic RAG Pipeline

Build sophisticated RAG workflows with Arcana's composable Agent pipeline.

## Overview

The `Arcana.Agent` module provides a pipeline-based approach to RAG where a context struct flows through each step:

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, LangChain.chat(prompt)} end

ctx =
  Agent.new("Compare Elixir and Erlang", repo: MyApp.Repo, llm: llm)
  |> Agent.rewrite()     # Clean up conversational input
  |> Agent.expand()      # Expand query with synonyms
  |> Agent.decompose()   # Break into sub-questions
  |> Agent.search()      # Search for each sub-question
  |> Agent.rerank()      # Re-rank results
  |> Agent.answer()      # Generate final answer

ctx.answer
```

## Pipeline Steps

### new/2 - Initialize Context

Creates the context with your question and configuration:

```elixir
ctx = Agent.new("What is Elixir?",
  repo: MyApp.Repo,
  llm: llm,
  limit: 5,        # Max chunks per search
  threshold: 0.5   # Minimum similarity
)
```

### rewrite/2 - Clean Conversational Input

Transform conversational input into clear search queries:

```elixir
ctx = Agent.rewrite(ctx)

ctx.rewritten_query
# "Hey, I want to compare Elixir and Go" → "compare Elixir and Go"
```

This step removes greetings, filler phrases, and conversational noise while preserving entity names and technical terms. Use when questions come from chatbots or voice interfaces.

### select/2 - Route to Collections

Route the question to specific collections based on content:

```elixir
ctx
|> Agent.select(collections: ["docs", "api", "tutorials"])
|> Agent.search()
```

The LLM decides which collection(s) are most relevant. Collection descriptions (if set) are included in the prompt.

### expand/2 - Query Expansion

Add synonyms and related terms to improve retrieval:

```elixir
ctx = Agent.expand(ctx)

ctx.expanded_query
# => "Elixir programming language functional BEAM Erlang VM"
```

### decompose/2 - Query Decomposition

Break complex questions into simpler sub-questions:

```elixir
ctx = Agent.decompose(ctx)

ctx.sub_questions
# => ["What is Elixir?", "What is Erlang?", "How do they compare?"]
```

### search/2 - Execute Search

Search using the original question, expanded query, or sub-questions:

```elixir
ctx = Agent.search(ctx)

ctx.results
# => [%{question: "...", collection: "...", chunks: [...]}]
```

#### Explicit Collection Selection

Pass `:collection` or `:collections` to search specific collections without using `select/2`:

```elixir
# Search a single collection
ctx
|> Agent.search(collection: "technical_docs")
|> Agent.answer()

# Search multiple collections
ctx
|> Agent.search(collections: ["docs", "faq"])
|> Agent.answer()
```

Collection selection priority:
1. `:collection`/`:collections` option passed to `search/2`
2. `ctx.collections` (set by `select/2`)
3. Falls back to `"default"` collection

This is useful when:
- You have only one collection (no LLM selection needed)
- The user explicitly chooses which collection(s) to search
- You want deterministic routing without LLM overhead

### rerank/2 - Re-rank Results

Score and filter chunks by relevance:

```elixir
ctx = Agent.rerank(ctx, threshold: 7)
```

See the [Re-ranking Guide](reranking.md) for details.

### answer/2 - Generate Answer

Generate the final answer from retrieved context:

```elixir
ctx = Agent.answer(ctx)

ctx.answer
# => "Elixir is a functional programming language..."
ctx.context_used
# => [%Arcana.Chunk{...}, ...]
```

#### Self-Correcting Answers

Enable self-correction to evaluate and refine answers:

```elixir
ctx = Agent.answer(ctx, self_correct: true, max_corrections: 2)

ctx.answer           # Final (possibly refined) answer
ctx.correction_count # Number of corrections made
ctx.corrections      # List of {previous_answer, feedback} tuples
```

When `self_correct: true`, the pipeline:
1. Generates an initial answer
2. Evaluates if the answer is grounded in the retrieved context
3. If not grounded, regenerates with feedback
4. Repeats up to `max_corrections` times (default: 2)

This reduces hallucinations by ensuring answers are well-supported by the context.

## Custom Prompts

Every LLM-powered step accepts a custom prompt function and optional LLM override:

```elixir
# Custom rewrite prompt
Agent.rewrite(ctx, prompt: fn question ->
  "Clean up this conversational input: #{question}"
end)

# Custom expansion prompt
Agent.expand(ctx, prompt: fn question ->
  "Expand this query for better search: #{question}"
end)

# Custom decomposition prompt
Agent.decompose(ctx, prompt: fn question ->
  """
  Split this into sub-questions. Return JSON:
  {"sub_questions": ["q1", "q2"]}

  Question: #{question}
  """
end)

# Custom answer prompt
Agent.answer(ctx, prompt: fn question, chunks ->
  context = Enum.map_join(chunks, "\n", & &1.text)
  """
  Answer based only on this context:
  #{context}

  Question: #{question}
  """
end)

# Override LLM for a specific step
Agent.rewrite(ctx, llm: faster_llm)
Agent.answer(ctx, llm: more_capable_llm)
```

## Error Handling

Errors are stored in the context and propagate through the pipeline:

```elixir
ctx = Agent.new("Question", repo: repo, llm: llm)
  |> Agent.search()
  |> Agent.answer()

case ctx.error do
  nil -> IO.puts("Answer: #{ctx.answer}")
  error -> IO.puts("Error: #{inspect(error)}")
end
```

Steps skip execution when an error is present.

## Telemetry

Each step emits telemetry events:

```elixir
# Available events
[:arcana, :agent, :rewrite, :start | :stop | :exception]
[:arcana, :agent, :select, :start | :stop | :exception]
[:arcana, :agent, :expand, :start | :stop | :exception]
[:arcana, :agent, :decompose, :start | :stop | :exception]
[:arcana, :agent, :search, :start | :stop | :exception]
[:arcana, :agent, :rerank, :start | :stop | :exception]
[:arcana, :agent, :answer, :start | :stop | :exception]
[:arcana, :agent, :self_correct, :start | :stop | :exception]  # Per correction attempt
```

Example handler:

```elixir
:telemetry.attach(
  "agent-logger",
  [:arcana, :agent, :search, :stop],
  fn _event, measurements, metadata, _config ->
    IO.puts("Search found #{metadata.total_chunks} chunks in #{measurements.duration}ns")
  end,
  nil
)
```

## Example Pipelines

### Simple RAG

```elixir
ctx =
  Agent.new(question, repo: repo, llm: llm)
  |> Agent.search()
  |> Agent.answer()
```

### With Query Expansion

```elixir
ctx =
  Agent.new(question, repo: repo, llm: llm)
  |> Agent.expand()
  |> Agent.search()
  |> Agent.answer()
```

### Full Pipeline

```elixir
ctx =
  Agent.new(question, repo: repo, llm: llm)
  |> Agent.select(collections: ["docs", "api"])
  |> Agent.expand()
  |> Agent.decompose()
  |> Agent.search()
  |> Agent.rerank(threshold: 7)
  |> Agent.answer(self_correct: true)
```

### Conditional Steps

```elixir
ctx = Agent.new(question, repo: repo, llm: llm)

ctx =
  if complex_question?(question) do
    ctx |> Agent.decompose()
  else
    ctx |> Agent.expand()
  end

ctx
|> Agent.search()
|> Agent.rerank()
|> Agent.answer()
```

## Context Struct

The `Arcana.Agent.Context` struct carries all state:

| Field | Description |
|-------|-------------|
| `question` | Original question |
| `repo` | Ecto repo |
| `llm` | LLM function |
| `rewritten_query` | Query after cleanup (from rewrite) |
| `expanded_query` | Query after expansion |
| `sub_questions` | Decomposed questions |
| `collections` | Selected collections |
| `results` | Search results per question/collection |
| `rerank_scores` | Scores from re-ranking |
| `answer` | Final generated answer |
| `context_used` | Chunks used for answer |
| `correction_count` | Number of self-corrections made |
| `corrections` | List of `{answer, feedback}` tuples |
| `error` | Error if any step failed |
