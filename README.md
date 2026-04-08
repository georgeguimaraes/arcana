# Arcana 🔮📚

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fgeorgeguimaraes%2Farcana%2Fblob%2Fmain%2Flivebooks%2Farcana_tutorial.livemd)

An embeddable RAG library for Elixir and Phoenix. Arcana lets you add vector search, knowledge graphs, and LLM-driven retrieval to any app that already has an Ecto repo, without standing up a separate vector database, indexing service, or orchestration layer.

> [!TIP]
> See [arcana-adept](https://github.com/georgeguimaraes/arcana-adept) for a complete Phoenix app with the Doctor Who corpus pre-ingested and ready to query.

## Why this exists

Most RAG libraries are written in Python and assume you'll bolt them onto your stack via HTTP. That works, but it leaves you running a vector DB you don't otherwise need, juggling two languages, and gluing telemetry together across processes. The BEAM is particularly well-suited to RAG: pgvector is excellent, supervision trees are the right shape for long-running embedders and rerankers, telemetry is built into the platform, and your Phoenix app already has the Repo, the LiveView for the dashboard, and the user session for chat.

Arcana takes that observation seriously. Everything lives inside your app:

- **One Repo.** Documents, chunks, embeddings, and the knowledge graph are tables in your existing Postgres database. No new infrastructure.
- **Local-first by default.** Embeddings run on Bumblebee with EXLA, EMLX (Apple Silicon), or Torchx. The cross-encoder reranker is also local. You can swap to OpenAI/Cohere/whatever, but you don't have to.
- **One process model.** Embedders and rerankers are `Nx.Serving` instances under your supervision tree. Telemetry events are `:telemetry` spans you can already consume. There is no separate "RAG service" to operate.
- **Pluggable, but not abstract.** Every step that can be replaced is a behaviour with a single callback and a sensible default. Custom rerankers, custom searchers, custom answerers — they're all 10-line modules.

## Three modes of operation

Singh et al.'s 2025 [Agentic RAG survey](https://arxiv.org/abs/2501.09136) splits RAG systems into four progressively more flexible patterns. The key axis is **who decides the control flow**:

| Pattern | Flow decided by | What it looks like |
|---|---|---|
| **Naive RAG** | nobody, there is none | embed → retrieve → generate, one shot |
| **Advanced RAG** | author, at code time | naive + query rewriting, reranking, fusion |
| **Modular RAG** | author, at code time | composable pluggable steps you wire together |
| **Agentic RAG** | the LLM, at runtime | LLM picks tools each turn until it can answer |

Arcana ships three usage shapes that map onto the last three slots:

| Arcana surface | Singh slot | When to reach for it |
|---|---|---|
| `Arcana.search/2`, `Arcana.ask/2` | Advanced RAG | The default door. One call, sensible defaults: query rewriting, hybrid search, optional graph fusion, cross-encoder reranking. Use this unless you need more control. |
| `Arcana.Pipeline.*` | Modular RAG | Compose your own steps when you need control over order or behavior: `gate → rewrite → expand → decompose → search → reason → rerank → answer → ground`. Each step is a behaviour you can replace. |
| `Arcana.Loop.*` | Agentic RAG | Hand the wheel to the LLM. It picks tools (`search`, `answer`, `give_up`) each turn. Best for open-ended or multi-hop questions where the right sequence of searches isn't obvious upfront. |

Arcana intentionally does not ship a "Naive RAG" mode. Even the simplest entry point already does query rewriting, reranking, and graph fusion when available.

## How it feels

The shortest useful program:

```elixir
{:ok, _doc} = Arcana.ingest("Phoenix LiveView is a server-rendered UI library...", repo: MyApp.Repo)

{:ok, answer} = Arcana.ask("What is Phoenix LiveView?", repo: MyApp.Repo, llm: "openai:gpt-4o-mini")
```

When that's not enough, drop down to the Pipeline:

```elixir
alias Arcana.Pipeline

ctx =
  Pipeline.new("Compare Elixir and Erlang for building web services",
    repo: MyApp.Repo,
    llm: llm
  )
  |> Pipeline.rewrite()                                  # clean up conversational input
  |> Pipeline.select(collections: ["elixir", "erlang"])  # let the LLM pick collections
  |> Pipeline.decompose()                                # split into sub-questions
  |> Pipeline.search()                                   # search each one
  |> Pipeline.rerank()                                   # cross-encoder rerank
  |> Pipeline.answer()
  |> Pipeline.ground()                                   # NLI hallucination check

ctx.answer
ctx.grounding.score
```

When the right sequence of searches isn't knowable upfront, hand control to the LLM:

```elixir
{:ok, ctx} =
  Arcana.Loop.new("Find episodes where a Time Lord betrayed the Doctor",
    repo: MyApp.Repo,
    collection: "doctor-who"
  )
  |> Arcana.Loop.run(controller_llm: "openai:gpt-4o-mini")

ctx = Arcana.Loop.ground(ctx)  # optional: faithfulness scoring

ctx.answer
ctx.tool_history         # which tools the LLM picked, in order
ctx.terminated_by        # :answered, :gave_up, :max_iterations, or :error
ctx.grounding.score      # 0.0-1.0 if you called ground/2
```

When the corpus is split into multiple collections, pass them all to `new/2` and the controller picks which one to search per call. Pass a single collection to lock the loop to it; the controller physically can't express anything else (the tool schema won't even include the parameter). See the [Loop guide](guides/loop.md) for the lock vs pick semantics.

Loop also supports the standard router/answerer split: a cheap fast model picks tools each turn, and a stronger model writes the user-facing answer.

```elixir
Arcana.Loop.run(ctx,
  controller_llm: "zai:glm-4.5-flash",  # cheap, fast: picks tools
  answer_llm:     "zai:glm-4.6"         # stronger: writes the final answer
)
```

The controller drives the loop iterations, and when it commits via the `answer` tool, the answerer takes over and produces the final user-visible text from the same accumulated context. The same answerer is also used by the synthesis fallback when the loop runs out of budget without committing.

Each surface is a thin layer over the same primitives: chunkers, embedders, vector stores, graph stores, rerankers. You can mix and match — `Arcana.search/2` and `Arcana.Loop` both call into `Arcana.Searcher`, so a custom searcher you write for one is a custom searcher for all of them.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                Your Phoenix App                                 │
├──────────────────┬──────────────────┬──────────────────┬────────────────────────┤
│  Arcana.search/2 │   Arcana.ask/2   │  Arcana.Loop.*   │    Arcana.Pipeline.*   │
├──────────────────┴──────────────────┴──────────────────┴────────────────────────┤
│                                                                                 │
│  ┌──────────┐  ┌────────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐   │
│  │ Chunker  │  │  Embedder  │  │  Search  │  │ Reranker │  │   Grounding    │   │
│  └──────────┘  └────────────┘  └──────────┘  └──────────┘  └────────────────┘   │
│                                                                                 │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                              Knowledge Graph                              │  │
│  │  entity extraction → relationship linking → community detection (Leiden)  │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
│                                                                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                              Your Existing Ecto Repo                            │
│                          PostgreSQL + pgvector extension                        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

Everything between the top row (the four user-facing surfaces) and the Repo is pluggable. Default implementations cover the common case; behaviours let you swap any single piece without touching the rest.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```bash
mix igniter.install arcana
mix ecto.migrate
```

This adds the dependency, creates migrations, configures your Repo, and mounts the dashboard route.

For manual installation, supervision setup, embedder configuration, and the rest of the moving parts, see the [Getting Started guide](guides/getting-started.md).

## Documentation

The README is the brochure. The guides are the manual.

- [Getting Started](guides/getting-started.md) — installation, supervision tree, embedder and chunker setup, first ingestion, first query
- [LLM Integration](guides/llm-integration.md) — configuring providers (OpenAI, Anthropic, Z.ai, custom), passing per-call LLMs, model strings vs functions
- [Pipeline (Modular RAG)](guides/pipeline.md) — `Arcana.Pipeline`, every step in detail, custom behaviours, telemetry per step
- [Loop (Agentic RAG)](guides/loop.md) — `Arcana.Loop`, the default toolset, controller models, the system prompt, fallback synthesis
- [Search Algorithms](guides/search-algorithms.md) — semantic, fulltext, hybrid, RRF fusion, hybrid weights
- [Reranking](guides/reranking.md) — cross-encoder, ColBERT, LLM-based rerankers, when each is appropriate
- [GraphRAG](guides/graphrag.md) — entity extraction, community detection (Leiden), graph search, fusion with vector
- [Evaluation](guides/evaluation.md) — synthetic test sets, MRR / Recall / Hit metrics, evaluation runs
- [Telemetry](guides/telemetry.md) — every event Arcana emits, attaching handlers, hooking into Phoenix LiveDashboard
- [Dashboard](guides/dashboard.md) — the LiveView UI, mounting it, what it shows

## References

Arcana's design borrows heavily from published work. The implementation choices map back to specific papers wherever possible:

### RAG architecture and the agentic taxonomy

- [Agentic Retrieval-Augmented Generation: A Survey](https://arxiv.org/abs/2501.09136) (Singh et al., 2025) — the four-level taxonomy (Naive / Advanced / Modular / Agentic) that Arcana's three surfaces map onto
- [Self-RAG: Learning to Retrieve, Generate, and Critique through Self-Reflection](https://arxiv.org/abs/2310.11511) (Asai et al., ICLR 2024) — inspires `Pipeline.gate/2` and `Pipeline.ground/2`
- [Corrective Retrieval Augmented Generation (CRAG)](https://arxiv.org/abs/2401.15884) (Yan et al., 2024) — inspires the `self_correct: true` modes on `Pipeline.search/2` and `Pipeline.answer/2`

### Retrieval

- [Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods](https://dl.acm.org/doi/10.1145/1571941.1572114) (Cormack et al., SIGIR 2009) — RRF is the fusion algorithm Arcana uses to combine vector and full-text (and graph) results
- [Lost in the Middle: How Language Models Use Long Contexts](https://arxiv.org/abs/2307.03172) (Liu et al., 2023) — informs context ordering and the chunk count we ship as the default
- [Precise Zero-Shot Dense Retrieval without Relevance Labels (HyDE)](https://arxiv.org/abs/2212.10496) (Gao et al., 2022) — hypothetical document embeddings (planned, not yet shipped)

### GraphRAG

- [From Local to Global: A Graph RAG Approach to Query-Focused Summarization](https://arxiv.org/abs/2404.16130) (Microsoft, 2024) — the community-summary-based local search pattern Arcana implements
- [Graph Retrieval-Augmented Generation: A Survey](https://arxiv.org/abs/2408.08921) (2024) — comprehensive survey
- [HopRAG: Multi-Hop Reasoning for Knowledge-Aware RAG](https://arxiv.org/abs/2502.12442) (ACL 2025) — LLM-guided graph traversal

### Reranking

- Cross-encoder reranking via Bumblebee — `cross-encoder/ms-marco-MiniLM-L-6-v2` is the default. Cross-encoders consistently improve top-k accuracy by 10-25% over bi-encoder retrieval alone, and that held up in our doctor-who eval (MRR +39%, Hit@1 +62%).

### Agent prompting (informs `Arcana.Loop`)

- [Anthropic: Writing tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents) — heavy detail in tool descriptions, tell the model when NOT to call tools
- [Anthropic: Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — high-signal summaries from tools rather than raw chunk dumps
- [OpenAI: GPT-5 prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/gpt-5_prompting_guide) — soft language instead of `MUST`/`CRITICAL`, tool budget in the prompt alongside hard caps

### Evaluation and grounding

- [RAGAS: Automated Evaluation of Retrieval Augmented Generation](https://arxiv.org/abs/2309.15217) (Shahul et al., 2023) — faithfulness, relevance, context metrics
- [LettuceDetect: A Hallucination Detector for RAG](https://arxiv.org/abs/2502.17125) (2025) — token-level grounding, an alternative to the NLI scoring `Pipeline.ground/2` does today

## Roadmap

- [x] LiveView dashboard
- [x] Hybrid search (vector + full-text with RRF)
- [x] File ingestion (text, markdown, PDF)
- [x] Telemetry events for observability
- [x] In-memory vector store (HNSWLib backend)
- [x] Modular pipeline (`Arcana.Pipeline`) with pluggable behaviours for every step
- [x] Cross-encoder reranking (local, via Bumblebee)
- [x] GraphRAG (entity extraction, community summaries, fusion)
- [x] Agentic loop (`Arcana.Loop`) with native tool calling and fallback synthesis
- [x] E5 embedding model prefix support
- [ ] HyDE (Hypothetical Document Embeddings)
- [ ] Async ingestion via Oban
- [ ] Additional vector backends (TurboPuffer, ChromaDB)

## Development

```bash
docker compose up -d        # Postgres + pgvector
mix deps.get
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate
mix test
```

## License

Apache-2.0
