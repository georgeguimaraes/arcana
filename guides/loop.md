# Loop (Agentic RAG)

`Arcana.Loop` is Arcana's Agentic RAG surface: an LLM-driven tool loop where the controller picks tools each turn until it has enough context to answer the question, runs out of budget, or admits defeat.

This is the "Agentic RAG" pattern from Singh et al.'s 2025 [survey](https://arxiv.org/abs/2501.09136), as opposed to the static `Arcana.Pipeline` you compose ahead of time. Both patterns coexist in Arcana and target different problems.

## When to use Loop

Reach for `Arcana.Loop` when **the right sequence of searches isn't knowable upfront**. The LLM decides whether to search again, how to refine the query, and when to answer. Typical reasons:

- Open-ended exploratory questions ("what do we know about X")
- Multi-hop questions where each search depends on what the previous one returned
- Questions where the user's phrasing might or might not need rewriting, and you'd rather have the model decide
- "Find all the X" enumeration questions that benefit from iterative searching across different aspects

If you know the right pipeline ahead of time, use [`Arcana.Pipeline`](pipeline.md) — it's faster, cheaper, more predictable, and easier to debug.

If you just want a question answered with sensible defaults, use `Arcana.ask/2` — it's a one-call wrapper over the same primitives.

## Quick start

```elixir
{:ok, ctx} =
  Arcana.Loop.new("Find episodes where a Time Lord betrayed the Doctor",
    repo: MyApp.Repo,
    collection: "doctor-who"
  )
  |> Arcana.Loop.run(controller_llm: "openai:gpt-4o-mini")

ctx.answer            # the final answer text
ctx.tool_history      # list of tool calls the controller made, in order
ctx.terminated_by     # :answered | :gave_up | :max_iterations | :error
ctx.iterations        # how many controller turns ran
ctx.chunks            # all chunks accumulated across searches (capped)
```

## How the loop works

Each iteration is one round-trip with the controller LLM:

1. The controller is called with the running conversation (`ReqLLM.Context`) and the available tools
2. The controller responds with either tool calls or a final text answer
3. If tool calls: Loop executes them, appends results to the conversation, and goes back to step 1
4. If a terminating tool (`answer`, `give_up`) is called: Loop ends with that as the result
5. If `max_iterations` is hit before a terminating tool: Loop ends and (by default) does one final tool-less synthesis call to produce an answer from accumulated chunks

The loop is sequential and in-process. There's no parallel tool calling, no retry logic, and no streaming.

## The default toolset

Loop ships with **three tools**:

| Tool | What it does | Terminates the loop? |
|---|---|---|
| `search` | Search the knowledge base for chunks. Uses graph data automatically when available. | no |
| `answer` | Provide the final answer text. | yes (`:answered`) |
| `give_up` | Admit the question can't be answered. | yes (`:gave_up`) |

`search` is the only tool that touches your Repo. The other two terminate the loop with a result.

Query refinement and decomposition aren't separate tools — the system prompt tells the controller to mentally rewrite vague user questions before searching, and to issue sequential `search` calls with focused queries when a question covers multiple aspects.

To customize, pass `tools: [...]` to `Loop.run/2` with your own list of `ReqLLM.Tool` structs. Custom tools that mutate loop state need a matching clause in `Tools.execute/4`. See `Arcana.Loop.Tools` for the schemas of the default tools.

### What the controller sees from a search

The `search` tool returns the **full text** of up to 5 chunks per call, prefixed with stable chunk IDs:

```
Found 17 chunks. Top 5:

1. [62b23833-65a3-47fd-bcd5-6a42456ea734]
<full chunk text>

2. [01c9cdc6-8945-42d6-8335-ab9c4fcf19c5]
<full chunk text>

...
```

The controller is the answerer in this loop, and it needs the actual chunk text to decide whether what it has already retrieved is enough to answer. An earlier version returned 400-character previews based on Anthropic's general agent-engineering guidance to keep tool results terse. That guidance is correct for agents with many tools and many small results, but it's wrong for retrieval tools where the chunk text *is* the evidence the model needs. Truncated previews caused over-search: the model would refine queries indefinitely because no preview ever looked complete enough to commit. Self-RAG and CRAG (the two relevant Agentic RAG papers) both pass full passages, and that's the right model here too.

The cap on total chunks accumulated across the loop is governed by `:chunk_cap` (default 30), which bounds the loop's working memory but not what any single tool result contains.

## Configuration

```elixir
Arcana.Loop.new(question, opts) |> Arcana.Loop.run(opts)
```

`new/2` options:

| Option | Default | Description |
|---|---|---|
| `:repo` | `Arcana.Config.get(opts, :repo)` | Ecto repo for retrieval tools |
| `:collection` | `nil` | Lock the loop to a single collection. The controller physically cannot search anything else — the tool schema won't even expose a collection parameter. See "Collections: lock vs pick" below. |
| `:collections` | `[nil]` | Allowed set of collection names the controller may pick from per search call. When 2 or more, the search tool gains an optional `collection` parameter the controller uses to narrow the search. Overrides `:collection`. |

`run/2` options:

| Option | Default | Description |
|---|---|---|
| `:controller_llm` | required | Model spec for the loop **controller**: the model that picks tools each turn. ReqLLM string (`"openai:gpt-4o-mini"`), tuple (`{"zai:glm-4.6", api_key: "..."}`), or test stub function `(messages, tools, opts) -> {:ok, classified}` |
| `:answer_llm` | nil | Optional model spec for the **answerer**: the model that produces the user-facing text. When set, the controller drives the loop but `ctx.answer` is written by the answerer. See "Controller / answerer split" below. |
| `:max_iterations` | `10` | Hard cap on controller turns |
| `:tools` | `Tools.default/0` | List of `ReqLLM.Tool` structs. Replace to customize. |
| `:system_prompt` | `SystemPrompt.default/1` | Override the default system prompt. String or `(opts -> string)` |
| `:chunk_cap` | `30` | Maximum chunks accumulated across iterations. Lowest-scored evicted first. |
| `:fallback_synthesis` | `true` | When `max_iterations` is hit without `answer`, do one final tool-less LLM call to synthesize from accumulated chunks |
| `:synthesizer` | default | Override the synthesis function for the fallback path. `(messages, opts) -> {:ok, text}`. The default uses `:answer_llm` if set, otherwise `:controller_llm`. |
| `:search_fn` | `&Arcana.search/2` | Override `Arcana.search/2` for the built-in `search` tool. Test-only. |
| `:search_opts` | `[]` | Extra options forwarded to the search tool's call into `Arcana.search/2` |

You can also set defaults globally:

```elixir
config :arcana, loop: [
  controller_llm: "openai:gpt-4o-mini",
  max_iterations: 10,
  chunk_cap: 30
]
```

Per-call options override globals.

## Collections: lock vs pick

The `:collection` / `:collections` options on `Arcana.Loop.new/2` don't
just filter searches. They shape the **tool schema** the controller
sees, which determines what the controller can and can't express.

Three cases, three behaviors:

**Lock to a single collection.** Pass `:collection` or a one-element
`:collections` list. The `search` tool is built without a `collection`
parameter, so the controller literally has no way to express a
different collection. This is the strongest possible guarantee: no
prompt-engineering workaround, no "ignore previous instructions".

```elixir
Arcana.Loop.new(question, repo: Repo, collection: "docs")
# tool schema: search(query, limit)
# every search runs against "docs", always
```

**Allow a set; let the controller pick per call.** Pass a
multi-element `:collections` list. The `search` tool gains an optional
`collection` parameter whose documentation lists the allowed values.
The controller picks one per call, or omits it to search across all
listed collections. The system prompt also gains a "Collections"
section telling the controller when to narrow vs broaden.

```elixir
Arcana.Loop.new(question, repo: Repo, collections: ["docs", "wiki", "changelog"])
# tool schema: search(query, collection, limit)
# controller decides each call:
#   search(query: "...", collection: "docs")   -- narrow
#   search(query: "...")                        -- across all three
```

If the controller passes an invalid collection (not in the allowed
list), the search tool returns a friendly error as the tool result
(`"search error: collection \"x\" is not in the allowed list..."`).
The loop doesn't crash; the controller sees the error on its next
turn and can correct.

**Unrestricted.** Pass neither option. The search tool has no
`collection` parameter. `Arcana.search/2` is called without a
collection filter, hitting whatever default behavior is configured.

```elixir
Arcana.Loop.new(question, repo: Repo)
# tool schema: search(query, limit)
# searches across whatever the default is
```

### When to use which

- **Lock** when your Loop is scoped to a single domain and you want to
  guarantee the controller never leaks into other collections. Common
  in multi-tenant apps where each tenant has its own collection.
- **Pick** when your corpus is split into topical collections and the
  right collection depends on the question. The controller can make
  that call per turn, which is exactly what you'd want an agent for.
- **Unrestricted** for the simplest case: one big corpus, no filtering.

## Termination

The loop ends in one of four states, recorded in `ctx.terminated_by`:

| Reason | What it means |
|---|---|
| `:answered` | The controller called the `answer` tool. `ctx.answer` is the text it provided. |
| `:gave_up` | The controller called the `give_up` tool. `ctx.answer` is `"Could not answer: <reason>"`. |
| `:max_iterations` | The hard cap fired before a terminating tool was called. By default, fallback synthesis runs and `ctx.answer` is the synthesized text. With `fallback_synthesis: false`, `ctx.answer` is `nil`. |
| `:error` | The controller LLM call returned `{:error, reason}`. `ctx.error` carries the reason. No fallback runs. |

## Fallback synthesis

In practice, models reliably refuse to call `answer` for enumeration questions even with generous `max_iterations`. They keep hunting for completeness one entity at a time. This is a known agentic RAG failure mode.

Loop's fix is graceful degradation: when `max_iterations` is hit and chunks have been accumulated, do one more LLM call **without tools**. The model is forced to produce text, which it does, using the accumulated chunks as context. The result becomes `ctx.answer`.

```elixir
# Default synthesizer: appends an instruction to the running conversation,
# calls the controller_llm without tools, and returns the text.
{:ok, ctx} =
  Arcana.Loop.new("Which Time Lords have betrayed the Doctor?",
    repo: MyApp.Repo,
    collection: "doctor-who"
  )
  |> Arcana.Loop.run(controller_llm: "zai:glm-4.6", max_iterations: 6)

ctx.terminated_by     # :max_iterations
ctx.answer            # "Based on the available information, several Time Lords..."
```

To disable, pass `fallback_synthesis: false`. If you want a different model for the synthesis call than the controller, the simplest way is `:answer_llm` (see [Controller / answerer split](#controller--answerer-split)) — it acts as the default synthesizer when set. If you need full control over the synthesis call (custom prompt, postprocessing, retries), pass `:synthesizer` directly:

```elixir
Arcana.Loop.run(ctx,
  controller_llm: "zai:glm-4.5-flash",
  synthesizer: fn messages, _opts ->
    case ReqLLM.generate_text("zai:glm-4.6", messages) do
      {:ok, response} -> {:ok, ReqLLM.Response.text(response)}
      err -> err
    end
  end
)
```

## The system prompt

The default prompt (`Arcana.Loop.SystemPrompt.default/1`) follows current best practices from Anthropic and OpenAI:

1. **Structured into named markdown sections** (works across providers; XML tags don't)
2. **Heavy detail in tool descriptions, not the system prompt** — the prompt sets the role and workflow, the tool descriptions guide selection
3. **Explicit "when NOT to call" rules** to avoid the GPT-5 / Cursor over-eager-search failure mode
4. **Tool budget mentioned in the prompt** alongside the hard `max_iterations` cap
5. **No `Thought:/Action:` prefixes** — native tool calling drives the loop, no ReAct templating needed
6. **Self-critique on retrieval quality** before answering (Self-RAG / CRAG pattern)
7. **Soft language**, not aggressive `MUST` / `CRITICAL` — these cause overtrigger in Claude 4.5+

To override, pass `system_prompt: "..."` (a string) or `system_prompt: fn opts -> string end` (so you can read `:max_iterations` from opts to mention the budget). The default prompt is corpus-agnostic; if your corpus has unusual scoring characteristics or domain conventions, it's worth adding them in a custom prompt.

## Custom tools

Replace the default toolset with your own list of `ReqLLM.Tool` structs to add domain-specific tools (web search, calculator, SQL query, etc.):

```elixir
defmodule MyApp.LoopTools do
  alias ReqLLM.Tool

  def all do
    Arcana.Loop.Tools.default() ++ [my_calculator_tool()]
  end

  defp my_calculator_tool do
    Tool.new!(
      name: "calculate",
      description: "Evaluate an arithmetic expression. Use when the answer requires a numeric computation.",
      parameter_schema: [
        expression: [type: :string, required: true, doc: "An arithmetic expression like '2 + 2'"]
      ],
      callback: {__MODULE__, :no_op}
    )
  end

  def no_op(_), do: {:ok, nil}
end
```

The callback on `ReqLLM.Tool` is a placeholder — Loop executes tools itself via `Arcana.Loop.Tools.execute/4` so it can mutate the loop state. You'll need to add a clause to your own dispatch function (or fork `Tools.execute/4`) to handle the new tool.

If you only need to override the search tool without adding new tools, the simpler path is to pass `:search_fn` — see the test suite for an example.

## Controller / answerer split

Loop supports the standard router/answerer pattern: a cheap fast model picks tools each turn, and a stronger model writes the user-facing answer. Pass both `:controller_llm` and `:answer_llm`.

```elixir
Arcana.Loop.run(ctx,
  controller_llm: "zai:glm-4.5-flash",  # cheap, fast: picks tools
  answer_llm:     "zai:glm-4.6"         # stronger: writes the final answer
)
```

The two are independent. Each can be a ReqLLM model string, a `{model, opts}` tuple, or a function (the function form is mostly for tests). If `:answer_llm` is unset, the controller writes the answer too — current behavior, no change.

### Where the answerer fires

The answerer takes over the user-facing answer text on **two paths**:

1. **The controller calls the `answer` tool.** Normally this commits the controller's `text` argument as `ctx.answer`. With `:answer_llm` set, the loop instead makes one more LLM call to the answerer with the full conversation (which includes the controller's draft), plus an instruction to "write the final user-facing answer based on the chunks gathered above." Whatever the answerer returns becomes `ctx.answer`. If the answerer errors or returns nothing useful, the controller's draft text is used as a fallback so the user always gets *something*.

2. **The loop hits `max_iterations` and falls through to synthesis.** The default synthesizer uses `:answer_llm` if set, otherwise `:controller_llm`. So if you set `:answer_llm`, the synthesis fallback automatically uses your stronger model too. You can still override the entire synthesis path with `:synthesizer`, and that takes precedence over `:answer_llm` for the synthesis call only — the `answer` tool path still uses `:answer_llm` directly.

### Where the answerer does NOT fire

- **`give_up`.** When the controller calls the `give_up` tool, that's a failure signal: the model is saying "I can't answer this from the corpus." Rewriting that with a stronger model would just dress up failure in nicer prose, which is worse than the honest "I can't answer" message. `ctx.answer` for `:gave_up` is always the original `Could not answer: <reason>` text.

- **`:error` paths.** If the controller LLM call itself errors out, the loop terminates with `:error` and no answerer is invoked.

### Why split them

Two practical reasons:

- **Cost.** The controller runs on every iteration (5+ calls in a typical loop). The answerer runs once. If you use the same strong model for both, you're paying premium rates for tool selection, which is often a job a much cheaper model can do well. Splitting lets you use, e.g., `glm-4.5-flash` for the controller (cheap, fast) and `glm-4.6` or a frontier model for the answer (where quality matters most).

- **Quality where it counts.** Tool selection is a structured-output task. The model is choosing among 3 tools and emitting JSON arguments. Small models do this fine. Writing a well-structured answer from synthesized chunks is the hard part; that's where you want the strong model.

This is the standard pattern in production agent systems (Anthropic's [cost-optimization guide](https://docs.claude.com/en/docs/build-with-claude/prompt-caching), most LangChain agent setups). Loop just makes it a single-line option.

### When NOT to split

If you're already running on a frontier model for both, splitting buys you nothing. If your controller never makes it to the `answer` tool (always hits `:max_iterations`), the split only affects the synthesis fallback. If you want full control over how the final answer is produced (custom prompt, custom postprocessing, etc.), use `:synthesizer` instead — it's the lower-level escape hatch.

## Telemetry

Loop emits a single span around the whole run:

```elixir
[:arcana, :loop, :start | :stop | :exception]
```

Stop metadata includes:

| Key | Value |
|---|---|
| `:question` | The original question text |
| `:max_iterations` | The configured cap |
| `:tool_count` | How many tools the controller saw |
| `:iterations` | How many controller turns actually ran |
| `:terminated_by` | `:answered` / `:gave_up` / `:max_iterations` / `:error` |

For per-tool-call telemetry, attach to the `Arcana.search/2` events emitted from inside the search tool. Grounding (when you call `Loop.ground/2`) emits its own span under `[:arcana, :loop, :ground, :*]` — see the Grounding section below.

## Testing

Loop's controller can be a function, which makes unit testing trivial. The function signature is `(messages, tools, opts) -> {:ok, classified} | {:error, reason}` where `classified` is a map matching `ReqLLM.Response.classify/1`'s shape.

```elixir
test "loop terminates with :answered when controller calls answer" do
  controller = fn _msgs, _tools, _opts ->
    {:ok,
     %{
       type: :tool_calls,
       text: "",
       thinking: "",
       tool_calls: [%{id: "c1", name: "answer", arguments: %{"text" => "42"}}],
       finish_reason: :tool_calls
     }}
  end

  {:ok, ctx} =
    Arcana.Loop.new("question")
    |> Arcana.Loop.run(controller_llm: controller)

  assert ctx.terminated_by == :answered
  assert ctx.answer == "42"
end
```

For multi-turn tests, use a small `Agent` that holds a list of scripted responses and pops one per call. See `test/arcana/loop_test.exs` for the full pattern.

## Grounding

Loop doesn't run grounding automatically — it's expensive (runs an NLI model via Bumblebee) and you may not need it on every call. When you do want faithfulness scoring, pipe the result into `Arcana.Loop.ground/2`:

```elixir
{:ok, ctx} =
  Arcana.Loop.new(question, repo: repo, collection: collection)
  |> Arcana.Loop.run(controller_llm: llm)

ctx = Arcana.Loop.ground(ctx)

ctx.grounding.score               # 0.0-1.0 faithfulness
ctx.grounding.hallucinated_spans  # sentences not supported by accumulated chunks
ctx.grounding.faithful_spans      # supported sentences with chunk-ID attribution
```

### What it actually does

`Loop.ground/2` scores the answer in `ctx.answer` against the accumulated chunks in `ctx.chunks` using the configured grounder. The default grounder is `Arcana.Grounder.Hallmark`, which wraps [Hallmark](https://github.com/georgeguimaraes/hallmark) — a local Bumblebee integration for Vectara's HHEM model. Same grounder the Pipeline uses; the behaviour is context-agnostic.

Each sentence in the answer gets scored for faithfulness. Supported sentences go into `faithful_spans` with per-sentence chunk attribution (which chunks support the claim). Unsupported sentences go into `hallucinated_spans` with the same shape. The top-level `score` is a length-weighted average.

### Tool-call attribution

This is the Loop-specific piece. `Loop.ground/2` walks each span's `sources` and enriches them with the search iteration and query that produced each supporting chunk, using `ctx.tool_history`:

```elixir
[faithful_span | _] = ctx.grounding.faithful_spans

faithful_span.sources
# => [
#   %{
#     chunk_id: "abc-def",
#     score: 1.0,
#     search_iteration: 2,
#     search_query: "Rassilon betrayal Doctor"
#   },
#   ...
# ]
```

This maps each claim in the answer back to the specific agent decision (which search, at which iteration, with which query) that produced its supporting evidence. It's the [Agent GPA](https://arxiv.org/abs/2510.08847) pattern, end-of-loop rather than during trace, scoped to retrieval grounding rather than full tool-calling evaluation.

When a chunk was returned by multiple searches, Loop records the *earliest* iteration — "which search first discovered this chunk." If the grounder returns chunk IDs that aren't in `ctx.tool_history` (shouldn't normally happen, but defensive), `search_iteration` and `search_query` are `nil` on those sources rather than crashing.

### Reference set

Grounding runs against `ctx.chunks`, which is the full set of chunks the search tool accumulated across every iteration, capped at `chunk_cap` (default 30). This is the right reference set for Loop because the controller's conversation history literally contains every one of those chunks as tool result text — the answerer's working context is the accumulated set, not just the final-turn subset.

### When it's a no-op

`Loop.ground/2` returns the ctx unchanged when:

- The loop terminated with `:error` (there's no answer to ground)
- `ctx.answer` is `nil`
- `ctx.chunks` is empty (nothing to ground against)

Grounder errors are swallowed too: if the NLI model fails to load or times out, `ctx.grounding` stays `nil` and the rest of the context is untouched. Grounding is a nice-to-have annotation, not a fatal step — if scoring fails, you still get your answer.

### Custom grounders

Use the `:grounder` option to swap in a different implementation:

```elixir
# Module implementing Arcana.Grounder
Arcana.Loop.ground(ctx, grounder: MyApp.CustomGrounder)

# Or an inline function (answer, chunks, opts) -> {:ok, result} | {:error, reason}
Arcana.Loop.ground(ctx, grounder: fn answer, chunks, _opts ->
  {:ok, %Arcana.Grounding.Result{score: score_somehow(answer, chunks)}}
end)
```

The grounder behaviour is `Arcana.Grounder` — shared with Pipeline since the problem shape is the same. A custom grounder you write for Pipeline works for Loop unchanged.

### Telemetry

Grounding emits a span:

| Event | Metadata |
|---|---|
| `[:arcana, :loop, :ground, :*]` | `question`, `grounder`, `score`, `hallucinated_span_count`, `faithful_span_count` |

## Caveats

- **Cost.** Each iteration is a full LLM round-trip with the conversation history so far. A 6-iteration loop is 6+ LLM calls. Use cheap models for the controller and reserve strong models for synthesis.
- **Latency.** Sequential by design. With a typical chat-tier LLM, expect 5-10 seconds per iteration, so a 6-iteration loop takes 30-60 seconds wall-clock. Too slow for chat UIs that expect sub-second responses.
- **Variability.** The same question asked twice may take a different path. Telemetry and `ctx.tool_history` are how you reason about runs after the fact.
- **Provider compatibility.** Loop uses ReqLLM's tool calling, which works across providers, but each provider's tool support is slightly different. Z.ai (`zai:glm-4.6`) and OpenAI (`openai:gpt-*`) work in our test runs. Anthropic and Google should work but are less exercised.

## References

- [Agentic Retrieval-Augmented Generation: A Survey](https://arxiv.org/abs/2501.09136) (Singh et al., 2025)
- [Anthropic: Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
- [Anthropic: Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [OpenAI: GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)
- [Self-RAG (Asai et al., 2023)](https://arxiv.org/abs/2310.11511)
- [Corrective RAG (Yan et al., 2024)](https://arxiv.org/abs/2401.15884)
