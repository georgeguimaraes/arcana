# Agentic RAG Pipeline

Build sophisticated RAG workflows with Arcana's composable Agent pipeline.

## Overview

The `Arcana.Agent` module provides a pipeline-based approach to RAG where a context struct flows through each step:

```elixir
alias Arcana.Agent

ctx =
  Agent.new("Compare Elixir and Erlang")
  |> Agent.gate()        # Decide if retrieval is needed
  |> Agent.rewrite()     # Clean up conversational input
  |> Agent.expand()      # Expand query with synonyms
  |> Agent.decompose()   # Break into sub-questions
  |> Agent.search()      # Search for each sub-question
  |> Agent.reason()      # Multi-hop: search again if needed
  |> Agent.rerank()      # Re-rank results
  |> Agent.answer()      # Generate final answer
  |> Agent.ground()      # Detect hallucinations

ctx.answer
```

## Configuration

Configure defaults in your config so you don't have to pass them every time:

```elixir
# config/config.exs
config :arcana,
  repo: MyApp.Repo,
  llm: &MyApp.LLM.complete/1
```

You can still override per-call if needed:

```elixir
Agent.new("Question", repo: OtherRepo, llm: other_llm)
```

## Pipeline Steps

### new/1,2 - Initialize Context

Creates the context with your question and optional overrides:

```elixir
# Uses config defaults
ctx = Agent.new("What is Elixir?")

# With explicit options
ctx = Agent.new("What is Elixir?",
  repo: MyApp.Repo,
  llm: llm,
  limit: 5,        # Max chunks per search (default: 5)
  threshold: 0.5   # Minimum similarity (default: 0.5)
)
```

### gate/2 - Retrieval Gating

Decide if the question needs retrieval or can be answered from knowledge:

```elixir
ctx = Agent.gate(ctx)

ctx.skip_retrieval   # true if retrieval can be skipped
ctx.gate_reasoning   # "Basic arithmetic can be answered from knowledge"
```

When `skip_retrieval` is true, downstream steps behave differently:
- `search/2` skips the search and sets `results: []`
- `reason/2` skips multi-hop reasoning
- `rerank/2` passes through empty results
- `answer/2` uses a no-context prompt (answers from knowledge)

Use when:
- Your questions mix simple facts with domain-specific queries
- You want to reduce latency for questions that don't need retrieval
- You're building a chatbot that handles general knowledge questions

```elixir
# Example: skip retrieval for math questions
ctx =
  Agent.new("What is 2 + 2?", repo: MyApp.Repo, llm: llm)
  |> Agent.gate()
  |> Agent.search()
  |> Agent.answer()

ctx.skip_retrieval  # => true
ctx.answer          # => "4" (answered from knowledge, no retrieval)
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

### reason/2 - Multi-hop Reasoning

Evaluate if search results are sufficient and search again if not:

```elixir
ctx = Agent.reason(ctx, max_iterations: 2)

ctx.reason_iterations  # Number of additional searches performed
ctx.queries_tried      # MapSet of all queries attempted
```

This step implements multi-hop reasoning by:
1. Asking the LLM if current results can answer the question
2. If not, getting a follow-up query from the LLM
3. Executing the follow-up search and merging results
4. Repeating until sufficient or `max_iterations` reached

The `queries_tried` set prevents searching the same query twice.

#### Options

- `:max_iterations` - Maximum additional searches (default: 2)
- `:prompt` - Custom prompt function `fn question, chunks -> prompt_string end`
- `:llm` - Override the LLM function for this step

#### Example

```elixir
# Question that may need multiple searches
ctx =
  Agent.new("How does Elixir handle concurrency and error recovery?")
  |> Agent.search()
  |> Agent.reason(max_iterations: 3)
  |> Agent.answer()

# First search finds concurrency info, reason/2 adds error recovery search
ctx.reason_iterations  # => 1
ctx.queries_tried      # => MapSet.new(["How does Elixir...", "Elixir error recovery supervision"])
```

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

When `skip_retrieval` is true (set by `gate/2`), `answer/2` uses a no-context prompt and answers from the LLM's knowledge:

```elixir
ctx =
  Agent.new("What is 2 + 2?")
  |> Agent.gate()    # Sets skip_retrieval: true
  |> Agent.search()  # Skipped
  |> Agent.answer()  # Answers from knowledge

ctx.answer       # => "4"
ctx.context_used # => []
```

### ground/2 - Hallucination Detection

Check if the generated answer is faithful to the retrieved context:

```elixir
ctx = Agent.ground(ctx)

ctx.grounding.score              # 0.0-1.0 (fraction of faithful tokens)
ctx.grounding.hallucinated_spans # [%{text: "...", start: 0, end: 10, score: 0.95, sources: [...]}]
ctx.grounding.faithful_spans     # [%{text: "...", start: 11, end: 30, score: 0.98, sources: [...]}]
```

Each span includes a `:sources` field with chunk-level attribution: a list of `%{chunk_id: term(), score: float()}` sorted by word overlap score descending. This tells you which context chunks support (or contradict) each part of the answer.

#### Chunk Attribution

Use sources to trace claims back to specific chunks:

```elixir
# find hallucinated claims and the chunks they relate to
for span <- ctx.grounding.hallucinated_spans do
  IO.puts("Hallucinated: #{inspect(span.text)}")

  for source <- span.sources do
    chunk = Enum.find(ctx.context_used, &(&1.id == source.chunk_id))
    IO.puts("  chunk #{source.chunk_id} (overlap: #{Float.round(source.score, 2)})")
  end
end
```

Spans with empty sources have zero word overlap with any chunk, so the model fully invented them:

```elixir
fully_invented =
  Enum.filter(ctx.grounding.hallucinated_spans, &(&1.sources == []))
```

Hallucinated spans with high source overlap mean the words match but the facts are wrong (like saying "2010" when the chunk says "2011"):

```elixir
contradicted =
  ctx.grounding.hallucinated_spans
  |> Enum.flat_map(fn span ->
    span.sources
    |> Enum.filter(&(&1.score > 0.5))
    |> Enum.map(&{span.text, &1.chunk_id})
  end)
```

You can also see which chunks actually contributed to the answer:

```elixir
cited_chunk_ids =
  ctx.grounding.faithful_spans
  |> Enum.flat_map(& &1.sources)
  |> Enum.map(& &1.chunk_id)
  |> Enum.uniq()
```

The default grounder uses [LettuceDetect](https://huggingface.co/KRLabsOrg/lettucedect-base-modernbert-en-v1), a ModernBERT-based token classifier running via ONNX Runtime. It labels each token in the answer as faithful or hallucinated based on the retrieved context chunks.

Setup requires the `ortex` dependency and a one-time model download:

```bash
# Add to mix.exs: {:ortex, "~> 0.1"}
mix arcana.ground.setup
```

This downloads the pre-exported ONNX files (~600 MB total) from HuggingFace Hub to `priv/models/lettucedect/`. Use `--output-dir` to change the destination or `--force` to re-download.

For custom models, you can also export manually with `python scripts/export_lettuce_onnx.py --output-dir priv/models/lettucedect`.

```elixir
# config/config.exs
config :arcana, Arcana.Grounding.Serving,
  model_path: "priv/models/lettucedect/model.onnx"
```

Skips automatically if `ctx.error` is set or `ctx.answer` is nil.

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
[:arcana, :agent, :ground, :start | :stop | :exception]
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
  |> Agent.ground()
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

## Custom Implementations

Every pipeline step has a behaviour and can be replaced with a custom implementation. This gives you full control over each component while keeping the pipeline composable.

### Available Behaviours

| Step | Behaviour | Default Implementation | Option |
|------|-----------|----------------------|--------|
| `rewrite/2` | `Arcana.Agent.Rewriter` | `Rewriter.LLM` | `:rewriter` |
| `select/2` | `Arcana.Agent.Selector` | `Selector.LLM` | `:selector` |
| `expand/2` | `Arcana.Agent.Expander` | `Expander.LLM` | `:expander` |
| `decompose/2` | `Arcana.Agent.Decomposer` | `Decomposer.LLM` | `:decomposer` |
| `search/2` | `Arcana.Agent.Searcher` | `Searcher.Arcana` | `:searcher` |
| `rerank/2` | `Arcana.Agent.Reranker` | `Reranker.LLM` | `:reranker` |
| `answer/2` | `Arcana.Agent.Answerer` | `Answerer.LLM` | `:answerer` |
| `ground/2` | `Arcana.Agent.Grounder` | `Grounder.Lettuce` | `:grounder` |

### Custom Rewriter

Transform queries using your own logic:

```elixir
defmodule MyApp.SpellCheckRewriter do
  @behaviour Arcana.Agent.Rewriter

  @impl true
  def rewrite(question, _opts) do
    {:ok, MyApp.SpellChecker.correct(question)}
  end
end

ctx
|> Agent.rewrite(rewriter: MyApp.SpellCheckRewriter)
|> Agent.search()
```

### Custom Expander

Expand queries with domain-specific knowledge:

```elixir
defmodule MyApp.MedicalExpander do
  @behaviour Arcana.Agent.Expander

  @impl true
  def expand(question, _opts) do
    terms = MyApp.MedicalThesaurus.expand_terms(question)
    {:ok, question <> " " <> Enum.join(terms, " ")}
  end
end

Agent.expand(ctx, expander: MyApp.MedicalExpander)
```

### Custom Decomposer

Break questions into sub-questions with custom logic:

```elixir
defmodule MyApp.SimpleDecomposer do
  @behaviour Arcana.Agent.Decomposer

  @impl true
  def decompose(question, _opts) do
    sub_questions =
      question
      |> String.split(~r/ and | or /i)
      |> Enum.map(&String.trim/1)

    {:ok, sub_questions}
  end
end

Agent.decompose(ctx, decomposer: MyApp.SimpleDecomposer)
```

### Custom Searcher

Replace the default pgvector search with any backend:

```elixir
defmodule MyApp.ElasticsearchSearcher do
  @behaviour Arcana.Agent.Searcher

  @impl true
  def search(question, collection, opts) do
    limit = Keyword.get(opts, :limit, 5)

    chunks =
      MyApp.Elasticsearch.search(collection, question, size: limit)
      |> Enum.map(fn hit ->
        %{
          id: hit["_id"],
          text: hit["_source"]["text"],
          document_id: hit["_source"]["document_id"],
          score: hit["_score"]
        }
      end)

    {:ok, chunks}
  end
end

# Use Elasticsearch instead of pgvector
ctx
|> Agent.search(searcher: MyApp.ElasticsearchSearcher)
|> Agent.answer()
```

Other search backend examples:
- Meilisearch for fast typo-tolerant search
- Pinecone for managed vector search
- Weaviate for hybrid search
- OpenSearch for enterprise deployments

### Custom Reranker

Use a cross-encoder or other scoring model:

```elixir
defmodule MyApp.CrossEncoderReranker do
  @behaviour Arcana.Agent.Reranker

  @impl true
  def rerank(question, chunks, opts) do
    threshold = Keyword.get(opts, :threshold, 0.5)

    scored_chunks =
      chunks
      |> Enum.map(fn chunk ->
        score = MyApp.CrossEncoder.score(question, chunk.text)
        Map.put(chunk, :rerank_score, score)
      end)
      |> Enum.filter(&(&1.rerank_score >= threshold))
      |> Enum.sort_by(& &1.rerank_score, :desc)

    {:ok, scored_chunks}
  end
end

Agent.rerank(ctx, reranker: MyApp.CrossEncoderReranker)
```

### Custom Answerer

Generate answers with your own approach:

```elixir
defmodule MyApp.TemplateAnswerer do
  @behaviour Arcana.Agent.Answerer

  @impl true
  def answer(question, chunks, _opts) do
    context = Enum.map_join(chunks, "\n\n", & &1.text)

    answer = """
    Based on #{length(chunks)} sources:

    #{context}

    ---
    Question: #{question}
    """

    {:ok, answer}
  end
end

# Skip LLM entirely, just concatenate chunks
Agent.answer(ctx, answerer: MyApp.TemplateAnswerer)
```

### Custom Grounder

Replace the default LettuceDetect grounder with your own hallucination detection logic:

```elixir
defmodule MyApp.APIGrounder do
  @behaviour Arcana.Agent.Grounder

  @impl true
  def ground(answer, chunks, opts) do
    score = MyApp.FactChecker.check(answer, chunks)

    {:ok, %Arcana.Grounding.Result{
      score: score,
      hallucinated_spans: [],
      token_labels: []
    }}
  end
end

Agent.ground(ctx, grounder: MyApp.APIGrounder)
```

### Inline Functions

For quick customizations, pass a function instead of a module:

```elixir
# Inline rewriter
Agent.rewrite(ctx, rewriter: fn question, _opts ->
  {:ok, String.downcase(question)}
end)

# Inline expander
Agent.expand(ctx, expander: fn question, _opts ->
  {:ok, question <> " programming language"}
end)

# Inline searcher
Agent.search(ctx, searcher: fn question, collection, opts ->
  # Your search logic
  {:ok, chunks}
end)

# Inline answerer
Agent.answer(ctx, answerer: fn question, chunks, _opts ->
  {:ok, "Found #{length(chunks)} relevant chunks for: #{question}"}
end)

# Inline grounder
Agent.ground(ctx, grounder: fn answer, chunks, _opts ->
  {:ok, %Arcana.Grounding.Result{score: 1.0, hallucinated_spans: [], token_labels: []}}
end)
```

### Combining Custom Implementations

Mix and match custom components:

```elixir
ctx =
  Agent.new(question, repo: repo, llm: llm)
  |> Agent.rewrite(rewriter: MyApp.SpellCheckRewriter)
  |> Agent.expand()  # Use default LLM expander
  |> Agent.search(searcher: MyApp.ElasticsearchSearcher)
  |> Agent.rerank(reranker: MyApp.CrossEncoderReranker)
  |> Agent.answer()  # Use default LLM answerer
```

### Per-Step LLM Override

Override the LLM for specific steps without changing the implementation:

```elixir
fast_llm = fn prompt -> {:ok, OpenAI.chat("gpt-4o-mini", prompt)} end
smart_llm = fn prompt -> {:ok, OpenAI.chat("gpt-4o", prompt)} end

ctx =
  Agent.new(question, repo: repo, llm: fast_llm)
  |> Agent.expand()  # Uses fast_llm
  |> Agent.search()
  |> Agent.rerank()  # Uses fast_llm
  |> Agent.answer(llm: smart_llm)  # Override with smart_llm
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
| `grounding` | Grounding result (`%Arcana.Grounding.Result{}` or nil) |
| `error` | Error if any step failed |
