# Agentic RAG Pipeline

Build sophisticated RAG workflows with Arcana's composable Agent pipeline.

## Overview

The `Arcana.Agent` module provides a pipeline-based approach to RAG where a context struct flows through each step:

```elixir
alias Arcana.Agent

llm = fn prompt -> {:ok, LangChain.chat(prompt)} end

ctx =
  Agent.new("Compare Elixir and Erlang", repo: MyApp.Repo, llm: llm)
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

#### Self-Correcting Search

Automatically retry with rewritten queries when results are insufficient:

```elixir
ctx = Agent.search(ctx,
  self_correct: true,
  max_iterations: 3
)
```

The agent will:
1. Execute the search
2. Ask the LLM if results are sufficient
3. If not, rewrite the query and retry
4. Repeat until sufficient or max iterations reached

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

## Custom Prompts

Every LLM-powered step accepts a custom prompt function:

```elixir
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
[:arcana, :agent, :select, :start | :stop | :exception]
[:arcana, :agent, :expand, :start | :stop | :exception]
[:arcana, :agent, :decompose, :start | :stop | :exception]
[:arcana, :agent, :search, :start | :stop | :exception]
[:arcana, :agent, :rerank, :start | :stop | :exception]
[:arcana, :agent, :answer, :start | :stop | :exception]
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
  |> Agent.search(self_correct: true)
  |> Agent.rerank(threshold: 7)
  |> Agent.answer()
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
| `expanded_query` | Query after expansion |
| `sub_questions` | Decomposed questions |
| `collections` | Selected collections |
| `results` | Search results per question/collection |
| `rerank_scores` | Scores from re-ranking |
| `answer` | Final generated answer |
| `context_used` | Chunks used for answer |
| `error` | Error if any step failed |
