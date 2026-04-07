# Arcana.Pipeline + Arcana.Loop — Modular RAG and Agent Loop

## Overview

Two related changes:

1. **Rename** `Arcana.Agent` → `Arcana.Pipeline` to reflect what it actually is (a composed Modular RAG pipeline, not an autonomous agent). `Arcana.Agent` becomes a deprecated alias.
2. **Add** `Arcana.Loop` for the actually-agentic pattern: an LLM-driven loop that picks tools each iteration based on intermediate state.

This is a **breaking change** with a deprecation path: existing code keeps working through `Arcana.Agent` but emits compile-time warnings.

## Why rename

`Arcana.Agent` is misnamed. Looking at Singh et al.'s Agentic RAG survey taxonomy:

| Pattern | What it is | What we have |
|---------|-----------|--------------|
| Naive RAG | embed → retrieve → generate (one shot) | `Arcana.search/2`, `Arcana.ask/2` |
| Advanced RAG | + query rewriting, reranking | parts of current `Agent` |
| Modular RAG | composable pluggable steps via behaviours | **the rest of current `Agent`** |
| Agentic RAG | LLM-driven loop with tool use | **the new `Loop`** |

The current `Agent` is Modular RAG with corrective extensions (self_correct steps, multi-hop reason). It's pluggable, it's corrective, but it's not agentic — you compose it; the LLM doesn't drive it.

LlamaIndex calls this `QueryPipeline`. LangChain calls it `Chains`. The convention is clear: composition = pipeline/chain, LLM-loop = agent. Arcana's naming should match.

## Naming choice

`Arcana.Pipeline` for composition, `Arcana.Loop` for the agent loop. Reasoning:

- Short, role-based names match Elixir conventions (Phoenix.LiveView, Ecto.Multi, Oban.Worker)
- "RAG" is implicit since Arcana IS a RAG library — `Arcana.ModularRAG` would be redundant
- Code reads naturally: `Arcana.Pipeline.new(question) |> Arcana.Pipeline.search() |> ...`
- `Arcana.Loop` avoids the `Arcana.Agent.Loop` collision and is shorter
- The literature taxonomy lives in the moduledoc, not the module name

## Rename plan

### Phase 1: Add `Arcana.Pipeline`

- New file `lib/arcana/pipeline.ex` with the full implementation that's currently in `agent.ex`
- All step modules move from `Arcana.Agent.*` to `Arcana.Pipeline.*`:
  - `Arcana.Agent.Context` → `Arcana.Pipeline.Context`
  - `Arcana.Agent.Searcher` → `Arcana.Pipeline.Searcher`
  - `Arcana.Agent.Reranker` → `Arcana.Pipeline.Reranker`
  - `Arcana.Agent.Rewriter` → `Arcana.Pipeline.Rewriter`
  - etc. (10 step modules total)
- All tests move from `test/arcana/agent/*` to `test/arcana/pipeline/*`

### Phase 2: Deprecation alias

- Keep `lib/arcana/agent.ex` as a thin module that delegates everything to `Arcana.Pipeline`
- Each public function is a `defdelegate` with `@deprecated "Use Arcana.Pipeline instead"`
- Sub-modules (`Arcana.Agent.Context`, etc.) become deprecated aliases via `defmodule ... do; @deprecated ...; defdelegate, end` pattern
- Compile-time warnings appear when users call deprecated functions
- The deprecation period is one major version (2.0 → 3.0). Plan to remove in 3.0.

### Phase 3: Update internals

- The Phoenix dashboard at `/arcana` uses `Arcana.Agent.*` in several LiveViews. Update to `Arcana.Pipeline.*`.
- README, CHANGELOG, examples all use the new names.
- Telemetry events stay backward-compatible: `[:arcana, :agent, :search]` is kept as an alias for `[:arcana, :pipeline, :search]` for one version.

### What does NOT change

- Behaviour names like `Arcana.Pipeline.Searcher` (formerly `Arcana.Agent.Searcher`) — same callbacks, just renamed module
- Function signatures and semantics
- Default arguments
- Telemetry data (just the event names get aliased)

### Breaking changes summary

- Module names: `Arcana.Agent.*` → `Arcana.Pipeline.*` (deprecated aliases provided)
- LiveView routes/internals (only matters if users have customized the dashboard)
- Custom user implementations of `Arcana.Agent.Searcher` (etc.) need to update their `@behaviour` line

The CHANGELOG entry reads:

```
## 2.0.0 — Breaking changes

### Renamed
- `Arcana.Agent` → `Arcana.Pipeline`. The old name remains as a deprecated
  alias and will be removed in 3.0. Update your supervision trees and any
  code that calls `Arcana.Agent.new/2`, `Arcana.Agent.search/2`, etc.
- All `Arcana.Agent.*` sub-modules renamed correspondingly. The
  `@behaviour` declarations in custom implementations need to update.

### Added
- `Arcana.Loop` — true agentic RAG with LLM-driven tool selection.
  See the moduledoc for design rationale and prompt patterns.
```

## Arcana.Loop — the agentic loop

A new module that runs an LLM-driven agent loop using ReqLLM's tool calling.

### Why a new module instead of folding into Pipeline

The two patterns are fundamentally different:

```elixir
# Pipeline (composed at call time, you decide the steps)
ctx |> Pipeline.gate() |> Pipeline.search() |> Pipeline.rerank() |> Pipeline.answer()

# Loop (LLM decides the steps)
ctx |> Loop.run(tools: [...], max_iterations: 5)
```

Mixing them in one module would conflate concerns. Keep them separate.

### What ReqLLM gives us

ReqLLM (1.6+) handles all the provider-agnostic tool calling work:

| Primitive | What it does |
|-----------|--------------|
| `ReqLLM.tool/1` | Define a tool with NimbleOptions schema validation |
| `tools:` option in `generate_text` | Pass tools to any supported provider |
| `ReqLLM.Response.classify/1` | Branch on `:tool_calls` vs `:final_answer` |
| `ReqLLM.Response.tool_calls/1` | Extract tool calls from a response |
| `ReqLLM.Context.execute_and_append_tools/3` | Run tools, append results |
| Provider normalization | OpenAI, Anthropic, Google, Z.ai, etc. all work the same way |

What we add: the loop runner, termination logic, state tracking, and telemetry.

### API

```elixir
# Simplest case
{:ok, answer} = Arcana.Loop.run("Find episodes where a Time Lord betrayed the Doctor")

# With explicit configuration
ctx =
  Arcana.Loop.new("Find episodes where a Time Lord betrayed the Doctor")
  |> Arcana.Loop.run(
    tools: Arcana.Loop.default_tools(),
    max_iterations: 5,
    controller_llm: "openai:gpt-4o-mini",  # cheap fast model for control
    answer_llm: "openai:gpt-4o",            # stronger model for the final answer
    chunk_cap: 30                            # max chunks accumulated across iterations
  )

ctx.answer
ctx.tool_history
# => [
#   %{tool: :search, args: %{query: "..."}, result_count: 5, iteration: 0},
#   %{tool: :rewrite, args: %{...}, iteration: 1},
#   %{tool: :search, args: %{query: "..."}, result_count: 8, iteration: 2},
#   %{tool: :answer, args: %{...}, iteration: 3}
# ]
ctx.loop_terminated_by  # :answered | :max_iterations | :error
ctx.loop_iterations
```

After the loop terminates, grounding runs as a separate step (not a tool):

```elixir
ctx
|> Arcana.Loop.run(...)
|> Arcana.Pipeline.ground()  # reuse Pipeline's grounder
```

### Configuration

```elixir
config :arcana, loop: [
  tools: :default,                     # or a list of ReqLLM.Tool structs
  max_iterations: 5,
  controller_llm: "openai:gpt-4o-mini",
  answer_llm: nil,                     # nil = use the same model as controller
  chunk_cap: 30
]
```

Per-call options override globals via the same `Arcana.Config.merge_app_opts/2` helper used by `search` and `ask`.

### Default tools

The default toolset is small. Research is unambiguous: LLMs degrade with too many tools (Anthropic recommends consolidating, OpenAI recommends "fewer than ~100 tools and fewer than ~20 arguments per tool" but the practical sweet spot is 5-10).

| Tool | What it does | Folds in graph? |
|------|--------------|-----------------|
| `search` | Vector + (optional) graph search for chunks | Yes — graph is automatic when the collection has graph data |
| `rewrite` | Rewrite the query for better retrieval | — |
| `decompose` | Break a multi-part question into sub-questions | — |
| `answer` | Generate the final answer (terminates the loop) | — |
| `give_up` | Stop trying, return what we have (terminates the loop) | — |

The `search` tool checks whether the collection has graph data and uses graph-enhanced search if so, plain vector search otherwise. This keeps the toolset small while still using the graph when available.

Users can replace `tools` with their own list of `ReqLLM.Tool` structs to add domain-specific tools (web search, calculator, SQL query, etc.).

### Terminating tools

`answer` and `give_up` are special: when called, the loop ends. The result returned from these tools becomes `ctx.answer`. All other tools accumulate state and continue the loop.

This makes `answer` a tool the LLM explicitly chooses to call (you decided that earlier). The benefit: the LLM can decide it has enough information rather than answering on every iteration.

### Tool result format

Tool results returned to the LLM are **summaries**, not full data. From Anthropic's "Effective context engineering": maintain lightweight identifiers and only load full content when needed.

Example for the `search` tool:

```elixir
# What the LLM sees:
"Found 5 chunks. Top 3:
1. [chunk_abc] The Master is a renegade Time Lord and the Doctor's nemesis... (score: 0.87)
2. [chunk_def] In 'The Time Monster', the Master poses as Professor Thascalos... (score: 0.81)
3. [chunk_ghi] Borusa was a Time Lord President who betrayed the Doctor in 'The Five Doctors'... (score: 0.76)"

# What's actually stored in ctx.results (full chunks for the answerer):
[%Chunk{id: "chunk_abc", text: "...", score: 0.87}, ...]
```

This separation lets the controller LLM make decisions on summaries (cheap) while the answerer has access to full chunks (expensive but only at the end).

### Chunk cap

Chunks accumulate across iterations in `ctx.results`. Without a cap, the answerer could see hundreds of chunks. With a cap (default: 30), older results get evicted when new ones arrive.

Eviction strategy: keep the highest-scored chunks across all iterations. The chunk_cap is configurable.

### Controller and answer models

You can configure two separate models:

- **`controller_llm`** — drives the loop. Cheap and fast (GPT-4o-mini, Haiku, GLM-4-Flash). Used for tool selection.
- **`answer_llm`** — generates the final answer. Stronger (GPT-4o, Claude Sonnet, GLM-5). Used only when the `answer` tool is called.

If `answer_llm` is nil, the controller is used for both. This is the simplest case and works fine for many applications.

### Termination

The loop terminates on any of:

1. **`answer` tool called** — happy path, LLM is satisfied. `loop_terminated_by: :answered`
2. **`give_up` tool called** — LLM admits defeat. `loop_terminated_by: :gave_up`
3. **`max_iterations` hit** — safety net. `loop_terminated_by: :max_iterations`
4. **Error** — LLM call failed or tool callback errored. `loop_terminated_by: :error`

`max_iterations` defaults to 5. Plenty for most cases.

### System prompt

Based on research from Anthropic, OpenAI, and the agentic RAG literature, the prompt follows these principles:

1. **Structured into named sections** (markdown headers, not XML tags since not all providers parse those equally)
2. **Heavy detail in tool descriptions, not the system prompt** — the prompt sets the role and workflow, the tool descriptions guide selection
3. **Explicit tell-when-not-to-call** rules to avoid over-eager tool use (Cursor/GPT-5 search-every-time failure)
4. **Tool budget mentioned in the prompt** even though `max_iterations` enforces it
5. **No "Thought:/Action:" prefixes** — native tool calling already gives us the loop
6. **Self-critique on retrieval quality** before answering (Self-RAG/CRAG pattern)
7. **Soft language**, not aggressive "CRITICAL" or "MUST" — these cause overtrigger

Template:

```text
You are a research agent answering questions about a knowledge base.

# Available tools

You have these tools:
- `search`: query the knowledge base
- `rewrite`: rephrase the query if results are weak
- `decompose`: split complex questions into sub-questions
- `answer`: provide the final answer (this ends the conversation)
- `give_up`: stop trying when the question can't be answered (also ends the conversation)

# Workflow

1. Start by searching for the original question.
2. If the results don't clearly answer the question, evaluate whether to:
   - Rewrite the query (try synonyms or different angle)
   - Decompose the question into smaller parts
   - Search again with what you've learned
3. When you have enough context, call `answer`.
4. If after 2-3 attempts you still can't find an answer, call `give_up`.

# When NOT to call tools

- Do not call `search` again with a query you've already tried.
- Do not call `decompose` on questions that are already simple and direct.
- Do not call `rewrite` more than once per search topic.

# Constraints

- Keep total tool calls under 5 unless the question is genuinely complex.
- Each search should target a specific aspect of the question, not the whole thing.
- Prefer fewer high-quality searches over many low-quality ones.

# Output

Call `answer` with a complete, well-structured response when ready.
The answer tool's argument should be the final answer text the user will see.
```

The system prompt is configurable via the `:system_prompt` option, but the default ships with this template.

### Tool descriptions (where the real work happens)

Per Anthropic's guidance, tool descriptions are the high-leverage place to fix misuse. Each tool gets 3-4 sentences covering: what it does, when to use, when NOT to use, parameter meanings.

```elixir
def search_tool do
  ReqLLM.tool(
    name: "search",
    description: """
    Search the knowledge base for chunks relevant to a query. Returns up to 5
    summaries with stable chunk IDs and similarity scores. Uses graph-enhanced
    retrieval automatically when the collection has a knowledge graph.

    Use this when you need information from the corpus to answer the user's
    question. Do not use it for general knowledge questions that don't require
    the corpus, and do not call it twice with the same query.
    """,
    parameter_schema: [
      query: [
        type: :string,
        required: true,
        doc: "The search query. Should be a focused phrase or question, not just keywords."
      ],
      limit: [
        type: :pos_integer,
        default: 5,
        doc: "Maximum chunks to return. Keep low (3-5) unless gathering comprehensive context."
      ]
    ],
    callback: {Arcana.Loop.Tools, :execute_search}
  )
end
```

### Telemetry

Each iteration emits events at `[:arcana, :loop, :*]`:

- `[:arcana, :loop, :start]` — loop began, with `question`, `tools`, `max_iterations`
- `[:arcana, :loop, :iteration, :start]` — start of iteration N
- `[:arcana, :loop, :iteration, :stop]` — end of iteration N, with `tool_called`, `result_summary`
- `[:arcana, :loop, :tool_call]` — start/stop spans per tool execution
- `[:arcana, :loop, :stop]` — final, with `iterations`, `terminated_by`, `tool_history`

Essential for debugging. Without good traces, agent loops are nearly impossible to reason about.

## Implementation phases

Three commits, each independently useful:

### Commit 1: Rename `Agent` → `Pipeline` (breaking)

- Move `lib/arcana/agent.ex` to `lib/arcana/pipeline.ex` (and all sub-modules)
- Move `test/arcana/agent/*` to `test/arcana/pipeline/*`
- Update internal callers (LiveViews, README, CHANGELOG)
- Add deprecation aliases at `Arcana.Agent` that delegate with `@deprecated`
- Tests still pass, dashboard still works, deprecation warnings appear in compile output

### Commit 2: Add `Arcana.Loop` skeleton

- New module `lib/arcana/loop.ex` with `new/2`, `run/2`
- Default tool definitions in `lib/arcana/loop/tools.ex`
- System prompt in `lib/arcana/loop/system_prompt.ex` (just a function returning a string)
- Unit tests with a stub LLM (scripted tool call sequence)

### Commit 3: Wire `Arcana.Loop` into Adept

- Add a LiveView page or extend the existing Ask page with a "use loop" toggle
- Run the doctor-who corpus through Loop on a few example queries
- Document findings in `docs/evaluation-baseline.md`

## Open questions resolved

From the previous design doc, these are the answers:

1. **Separate controller model?** Yes, configurable. `controller_llm` and `answer_llm` are independent options. If `answer_llm` is nil, the controller is used for both.

2. **`graph_search` separate or folded?** Folded. The `search` tool uses graph automatically when the collection has graph data. Smaller toolset, better LLM accuracy.

3. **`answer` as a tool or finalization?** Tool. The LLM explicitly calls it when ready.

4. **Cap on accumulated chunks?** Yes. Default 30. Configurable via `chunk_cap`. Eviction: keep highest-scored across all iterations.

5. **Mid-loop grounding?** No. Grounding runs after the loop as a separate step (`|> Pipeline.ground()`).

## Test plan

### Pipeline rename

- All existing tests pass after the rename (656 tests in `test/arcana/agent/*` move to `test/arcana/pipeline/*`)
- New deprecation tests confirm `Arcana.Agent.search/2` still works and emits a warning

### Loop unit tests

- Stub LLM that returns a scripted sequence of tool calls
- Test termination on `answer`, `give_up`, `max_iterations`, error
- Test chunk cap eviction
- Test that `controller_llm` and `answer_llm` are used at the right times
- Test telemetry events fire with correct metadata

### Loop integration tests in Adept

- Tagged `:end_to_end`, excluded from default runs
- Run a small set of queries against the doctor-who corpus
- Compare answers from `Arcana.Pipeline` vs `Arcana.Loop` qualitatively
- Measure cost: LLM calls, tokens, latency

## Files to add or modify

### Rename phase

```
mv lib/arcana/agent.ex                    lib/arcana/pipeline.ex
mv lib/arcana/agent/                      lib/arcana/pipeline/
mv test/arcana/agent_test.exs             test/arcana/pipeline_test.exs
mv test/arcana/agent/                     test/arcana/pipeline/
new lib/arcana/agent.ex                   # deprecated alias module
new lib/arcana/agent/context.ex           # deprecated alias for sub-modules (~10 files)
update CHANGELOG.md
update README.md
update lib/arcana_web/live/ask_live.ex    # uses Arcana.Agent currently
```

### Loop phase

```
new lib/arcana/loop.ex                    # the runner
new lib/arcana/loop/tools.ex              # default tool definitions
new lib/arcana/loop/system_prompt.ex      # prompt template
new test/arcana/loop_test.exs             # unit tests with stub LLM
new test/arcana/loop/tools_test.exs       # tool callback tests
```

### Adept integration

```
new lib/adept_web/live/loop_demo_live.ex  # or extend ask_live.ex with a toggle
new test/adept_web/live/loop_demo_test.exs
update docs/evaluation-baseline.md         # add Loop comparison
```

## Out of scope for v1

- Multi-agent coordination (multiple LLMs collaborating)
- Parallel tool calls (running multiple tools simultaneously when the LLM requests them)
- Tool dependency graphs
- Cross-request state persistence (resumable agents)
- Streaming the loop (partial results as it progresses)

These can be added later. v1 is sequential, in-process, and bounded.

## Risks

**Risk: rename breaks user code more than expected.**
Mitigation: deprecation aliases delegate everything. Users get warnings, not errors.

**Risk: agent loop is too expensive in practice.**
Mitigation: cost warnings in the moduledoc, hard `max_iterations` default of 5, separate controller/answer models, telemetry to make cost visible.

**Risk: LLMs degrade with too many tools.**
Mitigation: ship a small default toolset (5 tools), folded graph search instead of separate tool, follow Anthropic's "fewer broader tools" guidance.

**Risk: agent loops fail in subtle ways (infinite loops, redundant calls, drift).**
Mitigation: hard iteration cap, system prompt explicitly tells LLM when NOT to call tools, tool descriptions are detailed (where the real work happens per Anthropic), telemetry for debugging.

## References

The prompt patterns and tool design follow current best practices from:

- [Anthropic: Define tools / Best practices](https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use)
- [Anthropic: Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents)
- [Anthropic: Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
- [OpenAI: GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide)
- [OpenAI: o3/o4-mini function calling](https://developers.openai.com/cookbook/examples/o-series/o3o4-mini_prompting_guide)
- [Self-RAG (Asai et al., 2023)](https://arxiv.org/abs/2310.11511)
- [Corrective RAG (Yan et al., 2024)](https://arxiv.org/abs/2401.15884)
- [Agentic RAG Survey (Singh et al., 2025)](https://arxiv.org/abs/2501.09136)

Key principles applied:
1. Tool descriptions do the heavy lifting, not the system prompt
2. Tell the model when NOT to call tools (avoids the GPT-5 / Cursor over-eager search failure)
3. Tool budget in the prompt + hard cap in the loop
4. Native tool calling (no Thought:/Action:/Observation: prefixes)
5. Self-critique on retrieval quality before answering
6. High-signal summaries from tools, not full data dumps
7. Soft language, not aggressive "CRITICAL"/"MUST" (causes overtrigger in Claude 4.5+)
