# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased (3.0.0)

Since v2.0.2, largely driven by feedback from a multi-tenant production
adoption (#94). The headline is that collection scoping can now fail closed,
search returns one shape in every mode, and the library no longer drags a
machine-learning toolchain into apps that bring their own embedder.

This is a major version. Read "Backwards incompatible changes" before
upgrading: eleven things break, and how you install and upgrade the schema
changes for everyone.

### Enhancements

  * [Arcana] Add `list_documents/1`, `count_documents/1` and `get_document/2`, so admin surfaces and tests can read documents through the public API instead of querying `Arcana.Document` directly
  * [Arcana] Add `replace: true` to `ingest/2`: re-ingesting a `(collection, source_id)` identity supersedes the previous document atomically, with old chunks staying searchable until the new ingest lands. It requires `:source_id` (an `ArgumentError` otherwise) and introduces `{:error, :replaced_by_concurrent_ingest}` when two ingests race for the same identity
  * [Arcana.Config] Add `strict_collections`, which turns an unknown collection name into `{:error, {:unknown_collection, name}}` instead of silently resolving to no filter. It is opt-in and still defaults to `false` in 3.0. It covers more than search: under strict mode ingesting into a collection that does not exist yet errors instead of auto-creating it (the implicit `"default"` collection has to be created first), and the vector store's `store`/`delete`/`clear` and all five `Arcana.Maintenance` entry points are scoped the same way
  * [Arcana.Search] Add opt-in `graph_depth`, expanding matched entities through the relationships table before fetching chunks, with per-hop score decay. Defaults to `0` (previous behavior)
  * [Arcana.LLM] Accept `{module, function}` as an LLM. Unlike a captured function it serializes into a release's `sys.config`, so it no longer has to be wired in `runtime.exs`. `Arcana.Loop`'s `:controller_llm` and `:answer_llm` do not accept this form and raise an `ArgumentError`
  * [Arcana.Config] `repo!/1` is public, and supports a per-repo config shape: `config :arcana, MyApp.Repo, priv: "priv/my_repo"`. With exactly one such entry it is selected automatically (with a note on stderr); with several it raises unless `:repo` says which
  * [ArcanaWeb] The maintenance page gains a Summarize Communities action, with a hint counting what a run would process and a disabled state when no LLM is configured. Detection writes communities without summaries, and `ask(graph: true)` only injects the ones that have a summary, so detecting alone used to return no community context at all
  * [Arcana.Graph] `community_summary_level` accepts a list, a range or `:all`, so a query can draw on several levels of the community hierarchy at once
  * [Arcana.Maintenance] Add `configured_detector/0`, so callers can check the dependency the configured detector actually needs
  * [Arcana.Graph.CommunitySummarizer] Add `default_threshold/0`, so callers can predict what a summarize run will regenerate
  * [Arcana.Graph.GraphStore] Add an optional `sweep_orphans/2` callback. Custom graph stores that do not implement it keep working unchanged
  * [mix] New options: `--previous-dimensions` on `arcana.gen.embedding_migration` and `--dimensions` on `arcana.graph.install`, for when detection can't reach a running repo
  * [Arcana.Migration] New: Arcana owns its schema and records a version per install, so a host app writes one migration that delegates and upgrades by calling `up/1` again. Takes `:dimensions` for the embedding column, and `:prefix` to install into a Postgres schema of its own
  * [Arcana.Graph.Migration] The same for the GraphRAG tables, on its own version so an install that doesn't use GraphRAG is never dragged along
  * [Arcana.Graph.CommunitySummarizer] Add `content_fingerprint/2`, the digest of the entities and relationships a summary was generated from
  * [ArcanaWeb.Router] `arcana_dashboard` now derives every link and asset URL from the real mount point, so mounting anywhere other than `/arcana` works
  * [mix] `bumblebee` and `req_llm` are optional dependencies. Apps bringing their own embedder and LLM no longer compile roughly 13 transitive packages, including the tokenizers Rust NIF
  * [ArcanaWeb] The dashboard is optional at compile time: arcana now compiles in apps without Phoenix
  * [Arcana.FileParser] New behaviour and parser registry: `config :arcana, file_parsers: %{".docx" => MyParser}` routes an extension to your own parser, and `fallback_parser:` catches everything unmatched. Resolution runs registry, then built-ins, then fallback. Registering an extension as `false` disables it
  * [Arcana] Add `ingest_binary/2` for content that never touches the filesystem, such as bytes pulled from object storage. Requires `:filename` for extension routing and provenance. Parsers that need a real path (the built-in Poppler among them) return `{:error, {:binary_unsupported, module}}` rather than failing obscurely; a parser that is also unavailable reports that instead, since retrying through `ingest_file/2` would fail the same way. It shares the ingest path with `ingest_file/2`, so it builds graph data and honors `replace: true` on the same terms
  * [Arcana.Chunker.Default] Chunks carry `"start_byte"` and `"end_byte"` in their metadata, so a retrieved chunk can be located in the source document. Chunk metadata is now persisted for every chunker, honouring a contract that had been documented but never implemented
  * [Arcana.FileParser.PDF.Poppler] Report page byte ranges, which ingestion intersects with chunk offsets to add `"page_start"` and `"page_end"`. PDF citations carry page numbers with no new dependency
  * [ArcanaWeb.Router] `arcana_dashboard` accepts host-provided collection scoping, so one mount can be restricted to one tenant's collections. The scope is resolved once per page request and snapshotted into the LiveView session, so narrowing someone's permissions does not narrow a dashboard they already have open: to revoke promptly, set `live_socket_id` and broadcast a disconnect. Mounting the dashboard more than once needs the new `:live_session_name` option
  * [Arcana] `ingest_file/2` and `ingest_binary/2` route through the same finalize path as `ingest/2`, so file and binary ingestion finally get graph building and `replace: true` as well

### Bug fixes

  * [Arcana.Search] Named collections that resolve to nothing now match nothing on the graph path instead of widening to a global search, and under `strict_collections` an unknown name errors outright. Without strict mode the vector and keyword paths still fall back to searching unscoped for an unknown name, which is the historical behavior: multi-tenant setups should opt into strict mode
  * [Arcana.Search] `source_id` now scopes the graph path too. A source-scoped search used to leak chunks from other documents that happened to mention a matched entity, and `Arcana.ask/2` did the same for entities and relationships
  * [Arcana.Graph] Entity names are normalized on both sides of every comparison in Postgres, which lowercases, folds underscores and hyphens to spaces, and collapses runs of whitespace. `Two_Year_Limited_Warranty`, `two-year limited warranty` and `Two Year Limited Warranty` are now one entity rather than three. There is no Unicode normalization pass, so precomposed and decomposed forms still differ. Names no longer split into duplicate entities, or collide with themselves and abort an ingest. Dedup outcomes on existing graphs change accordingly
  * [mix arcana.install] Create `arcana_evaluation_test_cases.reference_answer`. `Arcana.Evaluation.TestCase` has declared the field and `Arcana.Evaluation` has read it for a release, but no installer template ever created the column, so evaluation queries failed on a fresh install
  * [Arcana.Graph.GraphStore] `delete_by_chunks/2` sweeps orphans only in the collections the chunks belonged to. It ran the sweep across every collection in the database and took no lock, so it could remove another tenant's entities and raced concurrent ingests: the only defense was a comment telling people not to call it. `Arcana.delete/2` remains the better entry point, since it removes the document, its chunks and their graph data together
  * [ArcanaWeb] Dashboard flash messages render. Every maintenance action reported through `put_flash` and nothing ever rendered it, so a failed re-embed, a missing LLM or an unknown collection looked like nothing happening at all
  * [ArcanaWeb] A maintenance action whose task dies now reports the failure instead of leaving the page on a spinner forever. Three of the four actions had no error handling, and the fourth used `rescue`, which never sees an exit such as a lost database connection
  * [ArcanaWeb] The Summarize Communities action honors host-provided collection scoping. It was added after the other three maintenance actions and skipped their validation, so on a restricted dashboard an unscoped run summarized every tenant's communities, a forged selection reached the summarizer, and the hint counted rows the host had no access to
  * [Arcana.Maintenance] A carried-over community summary is queued for a refresh when the content behind it changed. Membership was standing in for content, but a summary is written from the community's relationships too, so ingesting another document added relationships without moving anyone between communities and the summary stayed clean forever. Communities now record what their summary was generated from and the rebuild compares it, so an unchanged community still skips the LLM call
  * [Arcana.Maintenance] Summary reuse keys on level as well as membership. Two levels sharing an entity set collapsed to one key, so a level-0 community could come back holding the level-1 summary, decided by whichever row Postgres returned last
  * [ArcanaWeb] The summarize hint counts exactly what a run would process, applying the same rule as `CommunitySummarizer.needs_regeneration?/2` rather than diverging from it in both directions
  * [Arcana.Maintenance] Community detection honors `seed`, `objective`, `iterations` and the other knobs from `config :arcana, :graph`, and honors `community_detector` instead of hardcoding Leiden. Entity and relationship fetches are ordered too: detectors index nodes by position, so a pinned seed only reproduces when the input order does
  * [Arcana.Maintenance] Rebuilding communities carries summaries over to unchanged memberships instead of recreating every row with a nil summary, which had cost one LLM call per community on every rebuild
  * [Arcana.Maintenance] Summarization only processes levels a query path actually reads, instead of paying per row on levels nothing consumes
  * [Arcana.Ask] Community summaries are chosen by how much they overlap the matched entities, not by whatever order Postgres returned. The injection query had no `ORDER BY`, so when more communities were eligible than `community_summary_limit` allowed, the cut was arbitrary: the one community covering every matched entity could lose its slot to several sharing a single peripheral entity. Ties now favour smaller communities, which keeps a hub community that overlaps almost any entity set from spending a slot on a summary generalising over hundreds of loosely-related entities
  * [Arcana.Ask] The default prompt receives the graph context `ask/2` fetches. It was arity 2, so entities, relationships and community summaries reached only callers who passed their own arity-3 prompt
  * [Arcana.Graph] Reject a negative `community_summary_level`. `Community.changeset/2` only permits levels `>= 0`, so a negative selection silently matched nothing
  * [mix arcana.graph.detect_communities] Only require `leidenfold` when the built-in detector will actually run. A configured custom detector had to install a Rust NIF it never calls, and a missing custom detector module is now named instead of blamed on leidenfold
  * [mix arcana.graph.summarize_communities] Validate `--levels`: an empty value silently processed nothing, and a non-numeric one raised a bare `ArgumentError` that never mentioned the flag
  * [Arcana.Ecto.Vector] Compare vectors by encoded value, so re-storing a byte-identical embedding is a no-op instead of dirtying the changeset and churning the HNSW index on every ingest
  * [Arcana.Graph.CommunityDetector.Leiden] Stop storing duplicate partitions when the hierarchy converges before `max_level`, which had been multiplying summarization cost by the level count for no retrieval benefit
  * [ArcanaWeb] Dashboard CSS and navigation no longer 404 when the dashboard is mounted outside `/arcana`
  * [Arcana.Pipeline] `reason/2` inherits both the `:searcher` and the collections that `search/2` resolved, instead of falling back to the default searcher and to `["default"]`. Previously a scoped pipeline widened as soon as one follow-up iteration came back empty, and because an unknown collection name resolves to no filter without `strict_collections`, those follow-ups could read the whole corpus. Follow-up searches now run against the scope the original search used
  * [mix arcana.install] Never claim a Postgrex types module that already exists. The installer used to overwrite another library's types module, or point repo config at a module it had skipped generating; it now picks a free name, or stops with an error naming what is taken
  * [Arcana.FileParser.PDF.Poppler] The trailing form feed `pdftotext` emits no longer counts as an extra page
  * [Arcana.Reranker] The built-in LLM and cross-encoder rerankers attach a `:rerank_score` to the results they reorder, instead of returning chunks untouched
  * [Arcana] `Arcana.delete/2` sweeps the graph data belonging to a deleted document, rather than leaving orphaned entities and mentions behind
  * [mix arcana.gen.embedding_migration] Rolling back restores the previous vector size instead of a hardcoded one, and the previous size is read correctly when the repo is already started. When the previous size cannot be read and `--previous-dimensions` is not given, the generated `down` raises instead of silently reverting to 384: the migration is not reversible until you fill the size in
  * [Arcana.Config] `repo!/1` honors `repo: false` as an explicit "no repo". It backs every mix task through `Arcana.MixHelpers`, so `arcana.install`, `arcana.eval.generate`, `arcana.eval.run`, `arcana.gen.embedding_migration`, `arcana.graph.detect_communities`, `arcana.graph.embed_entities` and `arcana.graph.rebuild` all pick up the new behavior
  * [mix arcana.install] Validate the dimensions the configured embedder actually reports rather than trusting a flag
  * [mix arcana.graph.install] Detect the entity embedding dimension instead of assuming the default

### Backwards incompatible changes

  * [Arcana.Search] `search/2` returns `%Arcana.SearchResult{}` structs rather than plain maps, with the same fields in every mode (`vector_score`/`keyword_score` are `nil` where they don't apply, and chunk metadata is carried with string keys). The same structs now come back from `Arcana.ask/2`'s context and from `Arcana.Pipeline` results. The struct implements `Access`, so `result[:text]` keeps working; code that pattern matches on a bare map, or relies on a key being absent, needs updating. Custom `Arcana.Reranker` and `Arcana.Searcher` implementations receive the structs too: the reranker callback is now `[Arcana.SearchResult.t() | map()]`
  * [Arcana.SearchResult] The struct is deliberately not derived for `Jason.Encoder`/`JSON.Encoder`, so `Jason.encode!(results)` raises `Protocol.UndefinedError` where v2.0.2 returned encodable plain maps. Encode `Map.from_struct/1`, or derive the protocol yourself
  * [Arcana] `Arcana.delete/2` can now return `{:error, {:sweep_failed, reason}}`. The document is still deleted in that case, so `:ok = Arcana.delete(...)` needs updating
  * [Arcana.Graph] `community_levels` defaults to `1` (flat) instead of `5`. Four documented defaults disagreed and the most expensive won: on a 1444-entity graph that meant 1325 community rows where 265 were readable. Installs that relied on the deeper hierarchy, and the summarization cost that came with it, must set it explicitly
  * [ArcanaWeb.Router] The `on_mount` hook is renamed `ArcanaWeb.Router.Prefix` to `ArcanaWeb.Router.Scope`. Apps that named it in their own `on_mount` list must update it
  * [Arcana.Collection] `resolve_ids/2` returns `{:ok, nil} | {:ok, [uuid]} | {:error, {:unknown_collection, name}}` instead of `nil | [uuid]`
  * [Arcana.Migration] **Every install must run one migration to adopt versioned migrations.** Arcana's DDL used to live in the installer templates, with a separate mix task per later change; it now lives in `Arcana.Migration` and `Arcana.Graph.Migration`, which record a version per install. Write a migration calling `Arcana.Migration.up()` (and `Arcana.Graph.Migration.up()` if you use GraphRAG) and run it. Version 1 converges an existing database: it creates only what is absent and adds only what a later release introduced, so it drops nothing and re-runs nothing. It also applies both changes that shipped as standalone upgrade tasks, the entity-mention unique index and `communities.summary_fingerprint`, so those tasks are gone
  * [Arcana.Migration] **Deleting a collection that still has documents now fails instead of detaching them.** Every installer template shipped before versioned migrations emitted `on_delete: :nilify_all` on `arcana_documents.collection_id`, so deleting a collection silently set its documents' `collection_id` to `NULL`: they kept their chunks and stayed searchable while belonging to no collection, with nothing to tell you it had happened. Version 1 swaps the constraint to `ON DELETE RESTRICT`, so the delete is refused while documents remain. Delete the documents first, or reassign them. The dashboard explains the refusal rather than erroring
  * [Arcana.FileParser.PDF.Poppler] `parse/2` returns `{:ok, text, meta}` instead of `{:ok, text}`, where `meta` carries page byte ranges. A custom parser that delegates straight to it and matches `{:ok, text}` now raises a `MatchError`. Callers going through `Arcana.FileParser.PDF.parse/3` or `Arcana.Parser.parse/1` are unaffected: both still normalize to a two-tuple
  * [mix] `bumblebee` and `req_llm` are no longer pulled in transitively. Apps using the default local embedder must add `{:bumblebee, "~> 0.6"}` and a backend such as `{:exla, "~> 0.10"}`; apps passing model strings such as `"openai:gpt-4o-mini"` as the LLM, or using `Arcana.Loop`, must add `{:req_llm, "~> 1.2"}`. Both raise a message naming the missing dependency
  * [Arcana.TaskSupervisor] The supervisor now registers its process under `ArcanaWeb.TaskSupervisor`. Calling `Task.Supervisor.start_child(Arcana.TaskSupervisor, fun)` by the old registered name fails. The deprecated module still delegates `child_spec/1` and `start_child/1`, so only passing the module as a registered name to `Task.Supervisor` directly breaks

### Deprecations

  * [Arcana.TaskSupervisor] Renamed to `ArcanaWeb.TaskSupervisor`, since it only serves the dashboard's async operations. The old module still works as a supervision-tree child and starts the same process, with a deprecation warning

## [2.0.2](https://github.com/georgeguimaraes/arcana/compare/v2.0.1...v2.0.2) (2026-08-15)


### Bug Fixes

* **test:** Eliminate async config races, make every test file async: true ([#81](https://github.com/georgeguimaraes/arcana/issues/81)) ([0358b1e](https://github.com/georgeguimaraes/arcana/commit/0358b1ec1821e6d513a83859bba758e8c8d4ed33))


### Miscellaneous

* **deps-dev:** bump credo from 1.7.18 to 1.7.19 ([#86](https://github.com/georgeguimaraes/arcana/issues/86)) ([66d9dfa](https://github.com/georgeguimaraes/arcana/commit/66d9dfa768303a34333607a843056155aecaf932))
* **deps-dev:** bump floki from 0.38.1 to 0.38.4 ([#83](https://github.com/georgeguimaraes/arcana/issues/83)) ([07bca09](https://github.com/georgeguimaraes/arcana/commit/07bca0952e780f3c4dae1979f186c56212768438))
* **deps-dev:** bump lazy_html from 0.1.11 to 0.1.12 ([#82](https://github.com/georgeguimaraes/arcana/issues/82)) ([73954e0](https://github.com/georgeguimaraes/arcana/commit/73954e0df261565e4decdd2f9b0754acda994f3f))
* **deps:** bump igniter from 0.8.0 to 0.8.3 ([#85](https://github.com/georgeguimaraes/arcana/issues/85)) ([3786296](https://github.com/georgeguimaraes/arcana/commit/3786296e55ed55bf5b545865ef767a5c8a16c107))
* **deps:** bump mdex from 0.12.2 to 0.13.5 ([#89](https://github.com/georgeguimaraes/arcana/issues/89)) ([c33e069](https://github.com/georgeguimaraes/arcana/commit/c33e06990f83948e3a5ef9ddbf51b5555d976b17))
* **deps:** bump pgvector from 0.3.1 to 0.4.0 ([#84](https://github.com/georgeguimaraes/arcana/issues/84)) ([e0589ad](https://github.com/georgeguimaraes/arcana/commit/e0589ad97317a4bdd4a21982d0c10b97d23b7a5c))
* **deps:** bump phoenix_live_view from 1.2.7 to 1.2.8 ([#88](https://github.com/georgeguimaraes/arcana/issues/88)) ([b0db40b](https://github.com/georgeguimaraes/arcana/commit/b0db40b34345c13917ef1368693acb97bc7a4a54))
* **deps:** bump postgrex from 0.22.3 to 0.22.4 ([#93](https://github.com/georgeguimaraes/arcana/issues/93)) ([475e38a](https://github.com/georgeguimaraes/arcana/commit/475e38ac9499382cacaad3e76f495cf22d8d57fc))
* **deps:** bump req_llm from 1.17.1 to 1.19.0 ([#92](https://github.com/georgeguimaraes/arcana/issues/92)) ([baee901](https://github.com/georgeguimaraes/arcana/commit/baee901ac324dfb1071f65dd3de6cf52a20b9011))
* Fix type warning and prune stale lock entries ([#116](https://github.com/georgeguimaraes/arcana/issues/116)) ([4aa345a](https://github.com/georgeguimaraes/arcana/commit/4aa345aa35b3e999cfa6fb79c74eb678246be149))
* Fix type warning in graph_live and prune stale lock entries ([4aa345a](https://github.com/georgeguimaraes/arcana/commit/4aa345aa35b3e999cfa6fb79c74eb678246be149))

## [2.0.1](https://github.com/georgeguimaraes/arcana/compare/v2.0.0...v2.0.1) (2026-07-24)


### Miscellaneous

* **deps-dev:** bump ex_doc from 0.40.1 to 0.40.3 ([#78](https://github.com/georgeguimaraes/arcana/issues/78)) ([14d3578](https://github.com/georgeguimaraes/arcana/commit/14d3578e1b3c67ba4941581a14bbaddc810ab3d6))
* **deps:** bump actions/cache from 5 to 6 ([#80](https://github.com/georgeguimaraes/arcana/issues/80)) ([1fdcd42](https://github.com/georgeguimaraes/arcana/commit/1fdcd425e8fad55988f6fbc272aac1a42bb6ccf1))
* **deps:** bump actions/checkout from 6 to 7 ([#79](https://github.com/georgeguimaraes/arcana/issues/79)) ([c1ada78](https://github.com/georgeguimaraes/arcana/commit/c1ada783c36246db3ad33adcd97291b681e5884a))
* **deps:** bump igniter from 0.7.9 to 0.8.0 ([#77](https://github.com/georgeguimaraes/arcana/issues/77)) ([f97fcd9](https://github.com/georgeguimaraes/arcana/commit/f97fcd9d7573a3181d689ca28226328babf483bc))
* **deps:** bump phoenix_live_view from 1.1.28 to 1.2.7 ([#75](https://github.com/georgeguimaraes/arcana/issues/75)) ([dbdc817](https://github.com/georgeguimaraes/arcana/commit/dbdc8170bc7ab3d1b415b0e6dce8fae2992532bd))
* **deps:** bump postgrex from 0.22.0 to 0.22.3 ([#76](https://github.com/georgeguimaraes/arcana/issues/76)) ([bb55c13](https://github.com/georgeguimaraes/arcana/commit/bb55c135948dc925424b844a547983c6281e5faf))
* **deps:** bump req_llm from 1.10.0 to 1.17.1 ([#74](https://github.com/georgeguimaraes/arcana/issues/74)) ([dcd0921](https://github.com/georgeguimaraes/arcana/commit/dcd0921b5cfc2dd9e6a0272fd6084a3acdcaa317))


### Documentation

* **changelog:** merge hand-written 2.0.0 prose into release-please section ([c1cf916](https://github.com/georgeguimaraes/arcana/commit/c1cf9167857bdfe523aed53cd947b49df290e650))

## [2.0.0](https://github.com/georgeguimaraes/arcana/compare/v1.6.0...v2.0.0) (2026-04-24)


### ⚠ BREAKING CHANGES

- **Search modes renamed: `:semantic` → `:vector`, `:fulltext` → `:keyword`.**
  The new names are clearer about what the modes actually do: `:vector`
  matches by embedding similarity (pgvector cosine distance), `:keyword`
  matches literal terms (Postgres `tsvector`/`tsquery`), and `:hybrid`
  runs both and fuses via Reciprocal Rank Fusion. The old names
  `:semantic` and `:fulltext` are accepted at the public API surface
  but log a `Logger.warning` on use — they will be removed in a
  future release.

  **Affected surfaces:**

  - `Arcana.search(query, mode: ...)` — old atoms logged + normalized
  - `Arcana.ask(question, mode: ...)` — same
  - `Arcana.Evaluation.run(mode: ...)` — same
  - `mix arcana.eval.run --mode <mode>` — accepts `vector | keyword | hybrid`,
    old string values get a warning

  **Also renamed (no backward-compat, warnings only):**

  - Hybrid weight options: `:semantic_weight` → `:vector_weight`,
    `:fulltext_weight` → `:keyword_weight`. Passing old names logs a
    warning and falls back to the default 0.5 weight.
  - Hybrid result metadata keys: `:semantic_score` → `:vector_score`,
    `:fulltext_score` → `:keyword_score`. Callers destructuring these
    keys must update their code.
  - SQL layer aliases in `Arcana.VectorStore.Pgvector.search_hybrid/4`
    (internal, no public impact).

  **Migration:**

  ```elixir
  # Before
  Arcana.search("query", mode: :semantic)
  Arcana.search("query", mode: :fulltext)
  Arcana.search("query", mode: :hybrid, semantic_weight: 0.7, fulltext_weight: 0.3)

  # After
  Arcana.search("query", mode: :vector)
  Arcana.search("query", mode: :keyword)
  Arcana.search("query", mode: :hybrid, vector_weight: 0.7, keyword_weight: 0.3)
  ```

  If you persisted evaluation runs with `config.mode` as the old atoms,
  the UI will keep rendering them ("Mode: semantic") since config is
  stored as written at run time. New runs use the canonical names.

- **Renamed `Arcana.Agent` to `Arcana.Pipeline`.** The previous name was
  misleading: it described a composed Modular RAG pipeline, not an
  autonomous agent. The new name matches the literature (Singh et al.,
  2025) and conventions in LlamaIndex (`QueryPipeline`) and LangChain
  (`Chains`).

  - **Calls to `Arcana.Agent.*` functions still work** via a deprecated
    facade that delegates to `Arcana.Pipeline.*`. Compile-time deprecation
    warnings will appear. The facade will be removed in 3.0.
  - **Behaviour modules were renamed and are NOT aliased.** If you
    implement custom modules with `@behaviour Arcana.Agent.Reranker`,
    update them to `@behaviour Arcana.Reranker`. This is a
    one-line change. Affected behaviours:
    - `Arcana.Agent.Searcher` → `Arcana.Searcher`
    - `Arcana.Agent.Reranker` → `Arcana.Reranker`
    - `Arcana.Agent.Rewriter` → `Arcana.Pipeline.Rewriter`
    - `Arcana.Agent.Expander` → `Arcana.Pipeline.Expander`
    - `Arcana.Agent.Decomposer` → `Arcana.Pipeline.Decomposer`
    - `Arcana.Agent.Selector` → `Arcana.Pipeline.Selector`
    - `Arcana.Agent.Answerer` → `Arcana.Pipeline.Answerer`
    - `Arcana.Agent.Grounder` → `Arcana.Grounder`
  - The `Arcana.Agent.Context` struct is now `Arcana.Pipeline.Context`.
    Code that pattern matches on the struct module name needs updating.

- **Moved three cross-cutting behaviours out of the `Pipeline` namespace
  into the root `Arcana` namespace.** `Grounder`, `Searcher`, and
  `Reranker` are used by both `Arcana.Pipeline` and `Arcana.Loop` (and by
  `Arcana.search/2` for Searcher and Reranker), so they don't belong
  under `Arcana.Pipeline`. The five remaining step behaviours (`Rewriter`,
  `Expander`, `Decomposer`, `Selector`, `Answerer`) stay under
  `Arcana.Pipeline.*` because they're genuinely Pipeline-specific steps.

      Arcana.Pipeline.Grounder             → Arcana.Grounder
      Arcana.Pipeline.Grounder.Hallmark    → Arcana.Grounder.Hallmark
      Arcana.Pipeline.Searcher             → Arcana.Searcher
      Arcana.Pipeline.Searcher.Arcana      → Arcana.Searcher.Arcana
      Arcana.Pipeline.Reranker             → Arcana.Reranker
      Arcana.Pipeline.Reranker.LLM         → Arcana.Reranker.LLM
      Arcana.Pipeline.Reranker.CrossEncoder → Arcana.Reranker.CrossEncoder
      Arcana.Pipeline.Reranker.ColBERT     → Arcana.Reranker.ColBERT

  Update custom `@behaviour Arcana.Pipeline.Grounder` declarations,
  `config :arcana, reranker: Arcana.Pipeline.Reranker.CrossEncoder`
  entries, and any direct module references. No deprecated aliases at
  the `Arcana.Pipeline.*` level — this is a single hard rename. The
  `Arcana.Agent` facade from the first rename already covers users
  coming from the legacy `Agent.*` names.

- **Renamed pipeline telemetry events from `[:arcana, :agent, ...]` to
  `[:arcana, :pipeline, ...]`.** All eleven Pipeline step spans (gate,
  rewrite, select, expand, decompose, search, reason, rerank, answer,
  ground, self_correct) now emit under the `:pipeline` prefix. The
  legacy `:agent` prefix is no longer emitted at all. If you have
  custom telemetry handlers attached to `[:arcana, :agent, :*]`, update
  them to `[:arcana, :pipeline, :*]`. The metadata keys are unchanged.

- **Dashboard Ask page URL shape changed.** The Ask page moved from
  `/arcana/ask` (with a client-side mode toggle) to `/arcana/ask/<sub_tab>`.
  Existing bookmarks to `/arcana/ask` still land on the Advanced sub-tab
  by default, so they keep working.

### Added

- **`Arcana.Loop`** — Agentic RAG via an LLM-driven tool loop. Where
  `Arcana.Pipeline` composes RAG steps you decide ahead of time, `Loop`
  hands the wheel to the LLM: it picks tools (search, rewrite,
  decompose, answer, give_up) each turn until it can answer or hits
  `max_iterations`. Includes a fallback synthesis step that produces a
  final answer from accumulated chunks when the loop runs out of budget
  without an explicit `answer` call. Emits a single span at
  `[:arcana, :loop, :*]`. See the [Loop guide](guides/loop.md).

### Features

* **breaking:** rename search modes to :vector/:keyword, evaluation UX overhaul ([f1c59da](https://github.com/georgeguimaraes/arcana/commit/f1c59da477f4ef54e917e3fdb0694a1430f089bf))
* **config:** global config defaults and unified opts merging ([11880e1](https://github.com/georgeguimaraes/arcana/commit/11880e192aa9beffb9545a8e816ab05869e36fc7))
* **dashboard:** ChunkResults component, Loop grounding via LLMJudge ([b3dba78](https://github.com/georgeguimaraes/arcana/commit/b3dba7818c8ae2b89c9998954155d2b9635127f3))
* **dashboard:** compact Loop settings and simpler collection opts ([daa4cd8](https://github.com/georgeguimaraes/arcana/commit/daa4cd8f4c9c591741f5b5472b1a2a1cccfb5ec8))
* **dashboard:** markdown answers, live trace polish, role-aware temps ([7836d37](https://github.com/georgeguimaraes/arcana/commit/7836d37d01b81e22c097bb0323abb5b5a916f45b))
* **dashboard:** Pipeline UX overhaul ([eb999a0](https://github.com/georgeguimaraes/arcana/commit/eb999a0f5d568acd22a253bda63250918f1022cd))
* **dashboard:** rerank top_k, expanded Pipeline internals card ([87dac70](https://github.com/georgeguimaraes/arcana/commit/87dac70a168b53ae57fd1a8427ee6f6b468449fb))
* **dashboard:** sub-tab polish and live tracing for Ask ([958f7ce](https://github.com/georgeguimaraes/arcana/commit/958f7ce746a9ecf258031c169a536528f9c472ec))
* **dashboard:** thousand separators and tabular-nums on stats ([501a2f8](https://github.com/georgeguimaraes/arcana/commit/501a2f8652e3fb0827b11d4a2c3db05c48d200fc))
* **dashboard:** windowed pagination with prev/next and ellipsis ([aa3eba5](https://github.com/georgeguimaraes/arcana/commit/aa3eba5b2fd7158cafdec570bd5924e397413e43))
* **evaluation:** pluggable retriever and answer correctness scoring ([972375e](https://github.com/georgeguimaraes/arcana/commit/972375eb04267d2a2470accd579038ffd9f4e468))
* **graph:** community summary improvements and config extraction ([3967270](https://github.com/georgeguimaraes/arcana/commit/396727002627247c6e5805ba2b30f08e4bda6e73))
* **graph:** GraphRAG Local Search alignment ([27ed3f4](https://github.com/georgeguimaraes/arcana/commit/27ed3f44bdaf55b7ddee5bf062e6cbc0acd28311))
* **graph:** pluggable entity matcher for graph-enhanced search ([2b56205](https://github.com/georgeguimaraes/arcana/commit/2b562053c3c93aac2f6220b269b894eaeae0143a))
* **grounder:** LLMJudge with atomic claim decomposition ([d8f0525](https://github.com/georgeguimaraes/arcana/commit/d8f0525e9a8761419e188bcbd82a484451fa02e0))
* **loop:** Arcana.Loop (agentic RAG) with grounding and tool-call attribution ([b36c9b9](https://github.com/georgeguimaraes/arcana/commit/b36c9b958377e8b9111a8f6a8a22d27218cee24e))
* **loop:** custom tool callbacks, humanize guides ([5c525a4](https://github.com/georgeguimaraes/arcana/commit/5c525a4e98049ee430d666972b3746371f46f0e2))
* **loop:** per-call collection selection via dynamic search tool ([afc9724](https://github.com/georgeguimaraes/arcana/commit/afc9724aea2ac7638f307336954a6c99c685c339))
* **loop:** per-tool-call telemetry for live tracing ([aca51c2](https://github.com/georgeguimaraes/arcana/commit/aca51c2c22f32aa3658ce446864f47859a99e47c))
* **loop:** record synthesis fallback in tool_history ([980efb7](https://github.com/georgeguimaraes/arcana/commit/980efb77ab5837aa4c193e8db98e78e4481b0274))
* **loop:** role-specific temperatures and customizable answer prompts ([e3c2558](https://github.com/georgeguimaraes/arcana/commit/e3c25589b7af15059bd403e756f1a24a8195d061))
* **search:** local cross-encoder reranker via Bumblebee ([387e910](https://github.com/georgeguimaraes/arcana/commit/387e91081f51b1bdf87407290c37e9bde6791cb9))


### Bug Fixes

* **answer_metrics:** strip markdown code fences from LLM judge ([972375e](https://github.com/georgeguimaraes/arcana/commit/972375eb04267d2a2470accd579038ffd9f4e468))
* **graph:** pass entity metadata to Entity.changeset when upserting it ([#57](https://github.com/georgeguimaraes/arcana/issues/57)) ([3786969](https://github.com/georgeguimaraes/arcana/commit/3786969e19ca5a6f0ac18fe78298a7e13000cc38))
* **grounding:** drop hardcoded EXLA, defer to global Nx.Defn defaults ([cf46ec7](https://github.com/georgeguimaraes/arcana/commit/cf46ec739bc131d2471493079e1af9f3c312e7cf))
* **grounding:** per-chunk multi-pass NLI scoring, attach pipeline.ground telemetry ([29bd21f](https://github.com/georgeguimaraes/arcana/commit/29bd21f5029bc8317eec0068928359516c68e9f4))
* **grounding:** top-K budget-aware concat with per-chunk-max fallback, sharpen rewriter prompt ([ba705e2](https://github.com/georgeguimaraes/arcana/commit/ba705e2fbf30d39a121924987266e0b47daa2c3c))
* **pipeline:** gate + self-correct use Arcana.LLM protocol, skip_retrieval honored by prep steps ([b4bf007](https://github.com/georgeguimaraes/arcana/commit/b4bf00759e9b884167c39709710aef59afc57399))
* **pipeline:** rerank forwards all opts to reranker module ([2a3214a](https://github.com/georgeguimaraes/arcana/commit/2a3214a1cc6abc7cd61e631518d235c288846bc2))


### Miscellaneous

* **deps-dev:** bump credo from 1.7.17 to 1.7.18 ([#69](https://github.com/georgeguimaraes/arcana/issues/69)) ([18ada82](https://github.com/georgeguimaraes/arcana/commit/18ada82547e3022ab87c5788df63205672ac098c))
* **deps-dev:** bump floki from 0.38.0 to 0.38.1 ([#62](https://github.com/georgeguimaraes/arcana/issues/62)) ([f386462](https://github.com/georgeguimaraes/arcana/commit/f386462513f7dc67162144689f6cd91ac6c22582))
* **deps:** bump googleapis/release-please-action from 4 to 5 ([#71](https://github.com/georgeguimaraes/arcana/issues/71)) ([c5e51bb](https://github.com/georgeguimaraes/arcana/commit/c5e51bbfcc4f3cfa3bee979afb4dbf9fbfb1c4b1))
* **deps:** bump igniter from 0.7.2 to 0.7.3 ([#54](https://github.com/georgeguimaraes/arcana/issues/54)) ([1ac1dd9](https://github.com/georgeguimaraes/arcana/commit/1ac1dd9ef275d41562dcb4e6be7b8d4d29e871a9))
* **deps:** bump igniter from 0.7.3 to 0.7.6 ([#61](https://github.com/georgeguimaraes/arcana/issues/61)) ([d467e43](https://github.com/georgeguimaraes/arcana/commit/d467e43e5020885101698db0719270f50c080c73))
* **deps:** bump mdex from 0.12.1 to 0.12.2 ([#72](https://github.com/georgeguimaraes/arcana/issues/72)) ([19c797e](https://github.com/georgeguimaraes/arcana/commit/19c797e863e3acbfea0367f6e533bf181d8a31bd))
* **deps:** bump phoenix_live_view from 1.1.25 to 1.1.26 ([#53](https://github.com/georgeguimaraes/arcana/issues/53)) ([41b6724](https://github.com/georgeguimaraes/arcana/commit/41b6724341b0ce060704b31ff5adcf23b843d8ac))
* **deps:** bump phoenix_live_view from 1.1.26 to 1.1.27 ([#59](https://github.com/georgeguimaraes/arcana/issues/59)) ([29a3665](https://github.com/georgeguimaraes/arcana/commit/29a3665d0054447783694010dd1bd3cbe1dd6e8f))
* **deps:** bump req_llm from 1.6.0 to 1.7.1 ([#60](https://github.com/georgeguimaraes/arcana/issues/60)) ([2acdfe5](https://github.com/georgeguimaraes/arcana/commit/2acdfe5744c0411ddfb87738dd615eb2c254af6e))
* **deps:** bump req_llm from 1.7.1 to 1.8.0 ([#63](https://github.com/georgeguimaraes/arcana/issues/63)) ([d5a4197](https://github.com/georgeguimaraes/arcana/commit/d5a41978b20cfa157eac8ee1487d3e56bf94a2dd))
* **deps:** bump req_llm from 1.9.0 to 1.10.0 ([#70](https://github.com/georgeguimaraes/arcana/issues/70)) ([fe2c0da](https://github.com/georgeguimaraes/arcana/commit/fe2c0da03205cf5ba20c286dbed1158c9cd418a3))
* **deps:** update lockfile to latest compatible versions ([b1ae28b](https://github.com/georgeguimaraes/arcana/commit/b1ae28b6c55dbad355a32e04901ddee04e8b4066))
* fix credo --strict findings to unblock CI ([bb9d1b6](https://github.com/georgeguimaraes/arcana/commit/bb9d1b6e7f68b7de8137e7a6ac88fefc563e5214))
* **test:** use Tools alias to satisfy credo AliasUsage ([80ff3d3](https://github.com/georgeguimaraes/arcana/commit/80ff3d30f7e1e58130d82f0a56c215f5a50e35cc))


### Documentation

* **livebook:** add Loop section with multi-collection examples ([6aa4db2](https://github.com/georgeguimaraes/arcana/commit/6aa4db2c5e7e41ed0a8c294f04b1c59323747705))
* **readme:** align architecture diagram to uniform 83-char width ([d812dc5](https://github.com/georgeguimaraes/arcana/commit/d812dc5da3913a8f63851ccecac9b13dcf7c98d6))


### Code Refactoring

* **dashboard:** Ask sub-tabs, Evaluation retriever, Info sections ([16a06e6](https://github.com/georgeguimaraes/arcana/commit/16a06e622b73ce34538a41e5ccbe5d27c6c73b35))
* rename Arcana.Agent to Arcana.Pipeline ([6a0265c](https://github.com/georgeguimaraes/arcana/commit/6a0265c17da36cb53505fee9089237518953d406))

## [1.6.0](https://github.com/georgeguimaraes/arcana/compare/v1.5.2...v1.6.0) (2026-03-04)


### Features

* **ask:** redesign graph toggle as Graph-Assisted search ([98347ef](https://github.com/georgeguimaraes/arcana/commit/98347efd4b3a479cdbb3a4fbf339ca1895cbe828))
* **grounding:** Hallucination detection via Hallmark NLI ([#49](https://github.com/georgeguimaraes/arcana/issues/49)) ([de1b37f](https://github.com/georgeguimaraes/arcana/commit/de1b37f95fe4f11d6e92d202284e6bafd9b32505))


### Miscellaneous

* **deps-dev:** bump credo from 1.7.16 to 1.7.17 ([#51](https://github.com/georgeguimaraes/arcana/issues/51)) ([4ce74a7](https://github.com/georgeguimaraes/arcana/commit/4ce74a734927f23b2d5e02898adf39fef4cc0ea1))
* **deps:** bump ecto_sql from 3.13.4 to 3.13.5 ([#50](https://github.com/georgeguimaraes/arcana/issues/50)) ([e2a6be7](https://github.com/georgeguimaraes/arcana/commit/e2a6be7834ebc94d59ba4cf28caf7c8aea3b100b))
* **deps:** bump hallmark from 1.0.1 to 1.1.0 ([4f8b617](https://github.com/georgeguimaraes/arcana/commit/4f8b617631eff4d986a0fb9850f16c89ba7aa63b))


### Code Refactoring

* **reranker:** batch LLM reranking into a single call ([f59869d](https://github.com/georgeguimaraes/arcana/commit/f59869d80a2952453d0a9641e77677b0ecd073f0))

## [1.5.2](https://github.com/georgeguimaraes/arcana/compare/v1.5.1...v1.5.2) (2026-02-27)


### Miscellaneous

* **deps:** bump phoenix_live_view from 1.1.24 to 1.1.25 ([#47](https://github.com/georgeguimaraes/arcana/issues/47)) ([6fb0a0a](https://github.com/georgeguimaraes/arcana/commit/6fb0a0a5be8d10acf58348070f335106419608c0))

## [1.5.1](https://github.com/georgeguimaraes/arcana/compare/v1.5.0...v1.5.1) (2026-02-20)


### Miscellaneous

* **deps:** bump req_llm from 1.5.1 to 1.6.0 ([#45](https://github.com/georgeguimaraes/arcana/issues/45)) ([1913830](https://github.com/georgeguimaraes/arcana/commit/1913830d1edd229cf9e9d000944ad1f4e8b086cd))

## [1.5.0](https://github.com/georgeguimaraes/arcana/compare/v1.4.1...v1.5.0) (2026-02-19)


### Features

* **seach:** fix rrf search (graph results and vector results ids were on different format) ([#44](https://github.com/georgeguimaraes/arcana/issues/44)) ([f8c76f5](https://github.com/georgeguimaraes/arcana/commit/f8c76f54da2164c6921f3ee276e388d2654f296b))


### Miscellaneous

* **deps-dev:** bump lazy_html from 0.1.8 to 0.1.10 ([#42](https://github.com/georgeguimaraes/arcana/issues/42)) ([e3ac07c](https://github.com/georgeguimaraes/arcana/commit/e3ac07c61bee19c11f411ab1531ca63bec0dc4b1))
* **deps:** bump phoenix_live_view from 1.1.22 to 1.1.24 ([#41](https://github.com/georgeguimaraes/arcana/issues/41)) ([7b4be4f](https://github.com/georgeguimaraes/arcana/commit/7b4be4fe0ae95f5484296dea08bdefba3e7ae450))

## [1.4.1](https://github.com/georgeguimaraes/arcana/compare/v1.4.0...v1.4.1) (2026-02-17)


### Bug Fixes

* **ci:** chain hex-publish in release-please workflow ([6dbe46c](https://github.com/georgeguimaraes/arcana/commit/6dbe46c973663d915b92191b7f72f607f14ca592))
* **graphstore.ecto:** add metadata field to relationship persistence ([#37](https://github.com/georgeguimaraes/arcana/issues/37)) ([30483ce](https://github.com/georgeguimaraes/arcana/commit/30483ce5c4ee4c00bc98301d75d0abad55161d6f))


### Miscellaneous

* **deps-dev:** bump credo from 1.7.15 to 1.7.16 ([#34](https://github.com/georgeguimaraes/arcana/issues/34)) ([81d7849](https://github.com/georgeguimaraes/arcana/commit/81d78498cbeb5b28d78d5169484aea6821349e95))
* **deps-dev:** bump ex_doc from 0.40.0 to 0.40.1 ([#38](https://github.com/georgeguimaraes/arcana/issues/38)) ([30931fb](https://github.com/georgeguimaraes/arcana/commit/30931fb556f62175b8e5dae811d8fb28aa38b284))
* **deps:** bump igniter from 0.7.1 to 0.7.2 ([#36](https://github.com/georgeguimaraes/arcana/issues/36)) ([2f9e025](https://github.com/georgeguimaraes/arcana/commit/2f9e025b80249bcf413f8ffbb90d00caf351fc7f))
* **deps:** bump phoenix_live_view from 1.1.20 to 1.1.22 ([#35](https://github.com/georgeguimaraes/arcana/issues/35)) ([f44e877](https://github.com/georgeguimaraes/arcana/commit/f44e877f6d694d6815f55c13163f02cdb536a557))
* **deps:** bump req_llm from 1.2.0 to 1.3.0 ([#30](https://github.com/georgeguimaraes/arcana/issues/30)) ([09ce949](https://github.com/georgeguimaraes/arcana/commit/09ce949c091b8aa51aae9a57e232263f533388e4))
* **deps:** bump req_llm from 1.3.0 to 1.5.1 ([#40](https://github.com/georgeguimaraes/arcana/issues/40)) ([0dfa8d7](https://github.com/georgeguimaraes/arcana/commit/0dfa8d774215d59495b292ff61b0d3c05b1c7262))
* remove unused on-release workflow ([df5ff15](https://github.com/georgeguimaraes/arcana/commit/df5ff156e6972574ad6510f2b66855838c5d6824))

## [1.4.0](https://github.com/georgeguimaraes/arcana/compare/v1.3.3...v1.4.0) (2026-01-22)


### Features

* **dashboard:** add dynamic entity type and relationship options at graph_live.ex ([#29](https://github.com/georgeguimaraes/arcana/issues/29)) ([41ee981](https://github.com/georgeguimaraes/arcana/commit/41ee9811a26bd3699fe4e066a09edc92f0cc6ab8))


### Miscellaneous

* **deps-dev:** bump ex_doc from 0.39.3 to 0.40.0 ([#28](https://github.com/georgeguimaraes/arcana/issues/28)) ([8c1fb1f](https://github.com/georgeguimaraes/arcana/commit/8c1fb1f241c4440970fa72c7deda92ec4786c9fb))
* **deps:** bump igniter from 0.7.0 to 0.7.1 ([#31](https://github.com/georgeguimaraes/arcana/issues/31)) ([fcd441f](https://github.com/georgeguimaraes/arcana/commit/fcd441fdcc91f96043c1642098afdc44c264875f))


### Code Refactoring

* **ci:** use release-please for GitHub releases ([34f45c8](https://github.com/georgeguimaraes/arcana/commit/34f45c86721db54238fae141fec19dd9570c51bc))

## [1.3.3](https://github.com/georgeguimaraes/arcana/compare/v1.3.2...v1.3.3) (2026-01-20)


### Bug Fixes

* **dashboard:** flatten agentic results to fix KeyError on Ask page ([73e77a1](https://github.com/georgeguimaraes/arcana/commit/73e77a15f1356f46df283e1d1b5a72768e76de19)), closes [#25](https://github.com/georgeguimaraes/arcana/issues/25)

## [1.3.2](https://github.com/georgeguimaraes/arcana/compare/v1.3.1...v1.3.2) (2026-01-16)


### Miscellaneous

* **deps:** bump hnswlib from 0.1.6 to 0.1.7 ([#20](https://github.com/georgeguimaraes/arcana/issues/20)) ([6fb3b99](https://github.com/georgeguimaraes/arcana/commit/6fb3b991b94396005ba2802bcf832774192ccabb))
* **deps:** bump phoenix_live_view from 1.1.19 to 1.1.20 ([#21](https://github.com/georgeguimaraes/arcana/issues/21)) ([b1c298a](https://github.com/georgeguimaraes/arcana/commit/b1c298ad4117f5937e27d5ad3c60794554e23b24))
* **deps:** bump postgrex from 0.21.1 to 0.22.0 ([#19](https://github.com/georgeguimaraes/arcana/issues/19)) ([01410e1](https://github.com/georgeguimaraes/arcana/commit/01410e192180656c905263712fb7cb728c321605))
* **deps:** bump text_chunker from 0.5.2 to 0.6.0 ([#18](https://github.com/georgeguimaraes/arcana/issues/18)) ([c5ab08b](https://github.com/georgeguimaraes/arcana/commit/c5ab08b6130a010a96adeb9a2d38c766736a3ac0))


### Code Refactoring

* **ci:** remove redundant if from mark-release-tagged ([a8c7f4e](https://github.com/georgeguimaraes/arcana/commit/a8c7f4e34ebaab8a988816f8a77910e9ac992298))
* **ci:** use extract-version action ([2bd7ddc](https://github.com/georgeguimaraes/arcana/commit/2bd7ddcbafd9e24e842910ab6c1bf9f8a4183a4f))
* **ci:** use mark-release-tagged action ([3edb4b8](https://github.com/georgeguimaraes/arcana/commit/3edb4b883e4331e404a080b7d73e63c29832f9c1))
* **ci:** use shared workflows from georgeguimaraes/workflows ([9b8cab4](https://github.com/georgeguimaraes/arcana/commit/9b8cab4004f0d4104ce84e1913325e5a7f96a8cd))

## [1.3.1](https://github.com/georgeguimaraes/arcana/compare/v1.3.0...v1.3.1) (2026-01-16)


### Bug Fixes

* **ci:** checkout merge commit SHA when creating release tag ([f4d5a50](https://github.com/georgeguimaraes/arcana/commit/f4d5a50fe91f6b354c2a66e48003d8c842b5b341))
* **ci:** handle workflow_dispatch and yaml escaping issues ([149bfac](https://github.com/georgeguimaraes/arcana/commit/149bfacbe342918bcd145eb89ee3a89520f1c39a))
* support all forms of llm configuration on maintenance.ex ([#22](https://github.com/georgeguimaraes/arcana/issues/22)) ([6fec8f6](https://github.com/georgeguimaraes/arcana/commit/6fec8f6ed8b2477364202de6e052d7f010a8ec9d))


### Miscellaneous

* add fallback section for non-conventional commits in release-please ([5ec9e78](https://github.com/georgeguimaraes/arcana/commit/5ec9e7889ea090444ad0d18f00c2a386c6d3be77))

## [1.3.0](https://github.com/georgeguimaraes/arcana/compare/v1.2.0...v1.3.0) (2026-01-14)


### Features

* Add Build Graph button and mix arcana.rebuild_graph task ([d4f8aec](https://github.com/georgeguimaraes/arcana/commit/d4f8aec82f0188a38b9f49688ba8ed478d1e51cf))
* add ColBERT reranker using Stephen library ([7d078a0](https://github.com/georgeguimaraes/arcana/commit/7d078a01bd77389c908dd646bfc5a1985f785127))
* Add collection selector to Re-embed and improve displays ([950bb24](https://github.com/georgeguimaraes/arcana/commit/950bb249c2bfb99d8fffc6a2aec5c9375f0430af))
* Add collection selector to Rebuild Knowledge Graph ([abf7288](https://github.com/georgeguimaraes/arcana/commit/abf728891e03a1f702a1b9f56637c61e28c0a0ca))
* Add community detection maintenance task and UI ([d5e77e7](https://github.com/georgeguimaraes/arcana/commit/d5e77e74ecb71f3f7268b5be4a4d96beffb49f83))
* Add concurrency, resume and skip to rebuild_graph and reembed_chunks ([b023fa5](https://github.com/georgeguimaraes/arcana/commit/b023fa5eb08435143f2ccd6b0fbb0fc70fb46660))
* Add detailed stats to Collections page ([5f3d61e](https://github.com/georgeguimaraes/arcana/commit/5f3d61ef1fea4ca2cc001358daf2343edda34a26))
* Add fast Python leidenalg community detector ([78e00a2](https://github.com/georgeguimaraes/arcana/commit/78e00a27f7fb75375bc21d773ad92e9e3a34dc8e))
* Add gate and reason telemetry events to logger ([787becc](https://github.com/georgeguimaraes/arcana/commit/787becc0c7c2b6bb7031e9a1e8a25fecd8377b70))
* Add gate/2 and reason/2 for agentic RAG, split agent tests ([38dc6a1](https://github.com/georgeguimaraes/arcana/commit/38dc6a1a4e44c393c045be4ab8727a37843b862c))
* Add graph toggle to ingest and fix API key redaction ([c978452](https://github.com/georgeguimaraes/arcana/commit/c97845268b2f1df99e53d1554b00e68f3cd90033))
* Add hierarchical community detection with min_size filtering ([0648f4d](https://github.com/georgeguimaraes/arcana/commit/0648f4dcec9fa4caa76e66e9b81d6a27fd14452a))
* Add Leiden logging and CommunityDetector to Info page ([a7a04f3](https://github.com/georgeguimaraes/arcana/commit/a7a04f3b4c58bd683f015953b687866070bce193))
* Add mix arcana.graph.summarize_communities task ([ad42ed4](https://github.com/georgeguimaraes/arcana/commit/ad42ed4fd8e42cb5d65694af0ef557fb384eb417))
* Add orphaned graph data management to Maintenance page ([8d942fe](https://github.com/georgeguimaraes/arcana/commit/8d942fe26ec0b2a2994d3eacf2aff9f6183ebebe))
* Add pagination to graph explorer ([6797792](https://github.com/georgeguimaraes/arcana/commit/6797792bccce4a1d3c30ea2daff30b0de9f070a2))
* Add PDF parser behaviour for custom implementations ([08922bf](https://github.com/georgeguimaraes/arcana/commit/08922bfd9f242fa80464510eacf32205f4783c01))
* Add Rebuild Knowledge Graph to Maintenance page ([c9bc768](https://github.com/georgeguimaraes/arcana/commit/c9bc768efb5cc49c0d6ad9ab57d93a82662f22bf))
* Add theta option for faster Leiden convergence ([8e25236](https://github.com/georgeguimaraes/arcana/commit/8e2523661447e62cbee6c7d67c5837d9b00ae089))
* Display graph stats in dashboard when GraphRAG enabled ([ce1df09](https://github.com/georgeguimaraes/arcana/commit/ce1df095e4b7d853a3c783b971b29b9cfe418a94))
* Enhance Info page with more config details ([8d9a864](https://github.com/georgeguimaraes/arcana/commit/8d9a8649ae2c517d7b0fce18153086a62bf53853))
* Improve LLM select UI in Ask page ([acb71a8](https://github.com/georgeguimaraes/arcana/commit/acb71a8d5f69cce41db20116807d2b6f20ecd461))
* Pipeline components respect skip_retrieval flag ([ae65cb5](https://github.com/georgeguimaraes/arcana/commit/ae65cb5f45a96556bea8ec699140c072e4050420))
* Restructure Info page with expanded config display ([f6c1796](https://github.com/georgeguimaraes/arcana/commit/f6c1796602797e7520a7298f1731de0fc183335d))


### Bug Fixes

* Address Credo issues ([40387e2](https://github.com/georgeguimaraes/arcana/commit/40387e2f68e8d59e9881845a375652d517b027f9))
* Capture loading state from render_click return value ([3ecc10a](https://github.com/georgeguimaraes/arcana/commit/3ecc10aa2fe313c9b2d5f23f78d3de148b126591))
* **ci:** add include-v-in-tag to match existing tags ([4133649](https://github.com/georgeguimaraes/arcana/commit/4133649937dcdc2226d5d51e71d2c572dc2b2fa9))
* **ci:** add last-release-sha to bootstrap release-please state ([60ced9a](https://github.com/georgeguimaraes/arcana/commit/60ced9a47638d6d1134a74513bcef11b12a6395d))
* **ci:** bootstrap release-please to skip past PR [#6](https://github.com/georgeguimaraes/arcana/issues/6) ([de259ab](https://github.com/georgeguimaraes/arcana/commit/de259abb587a6b1eb625c6236206fbc1eec700c8))
* **ci:** match release PR title pattern to existing PRs ([0faf498](https://github.com/georgeguimaraes/arcana/commit/0faf4988273b6cc4d32baaff0c74bfbe7894f307))
* **ci:** update release PR label after creating release ([d121a13](https://github.com/georgeguimaraes/arcana/commit/d121a13252a3a95bdc4c7b5805899f8ec2617dd3))
* **ci:** use manifest mode for release-please ([710e659](https://github.com/georgeguimaraes/arcana/commit/710e6594f95241a283c97f91436cac97a26d8ed8))
* Convert indices to entity IDs in hierarchical community detection ([d387fd6](https://github.com/georgeguimaraes/arcana/commit/d387fd64fd7e316ee7c61c64f3a04c0b0b865118))
* credo warnings in ColBERT test ([39da83f](https://github.com/georgeguimaraes/arcana/commit/39da83f4078daf97833869e3e4882fe8e6014dac))
* Explicitly set enabled: false in test graph config ([662437f](https://github.com/georgeguimaraes/arcana/commit/662437ffc0ef6e4505565a28b7f2e7835e1390d3))
* Fix telemetry.span return value and add collection filter ([e2c9d22](https://github.com/georgeguimaraes/arcana/commit/e2c9d22b65d1d228700fc56123eccf017e1afd7d))
* Graph-Enhanced toggle styled as inline checkbox ([98fe03c](https://github.com/georgeguimaraes/arcana/commit/98fe03ce6bb807355edb87b640f6a291ad3187d1))
* Handle doc query param in documents page ([414046c](https://github.com/georgeguimaraes/arcana/commit/414046c232330bbe91d8f57801aafd2da1ee724d))
* Handle poppler_not_available error in PDF ingest test ([d33c409](https://github.com/georgeguimaraes/arcana/commit/d33c4097647656054416b9ddd5cd9f57508f6191))
* Improve community summary prompt to avoid generic intros ([b82471e](https://github.com/georgeguimaraes/arcana/commit/b82471e8d3dbdcd99adfab50cdd1f56ece3a5fb8))
* Join through Entity for relationship counts per collection ([87c5e18](https://github.com/georgeguimaraes/arcana/commit/87c5e182d79a7d89dd2e54bf34536cefada8bfc5))
* Lighten rel-type background and add section spacing ([ad3867c](https://github.com/georgeguimaraes/arcana/commit/ad3867ccd56e6cd8ca25b0824eab26d666d27909))
* Move Repository to info grid as card ([28d221e](https://github.com/georgeguimaraes/arcana/commit/28d221e238515add59ea419f7144caf1b5cb804a))
* Remove invalid collection_id queries from Relationship schema ([49ff631](https://github.com/georgeguimaraes/arcana/commit/49ff63181ce758aec1ed3f136c3b5eaee4011267))
* Remove long transactions from reembed to prevent DB timeout ([579b43d](https://github.com/georgeguimaraes/arcana/commit/579b43d8196592fc428ac717cae8da44a2993435))
* Reorganize Build Graph checkbox layout ([26a3bd4](https://github.com/georgeguimaraes/arcana/commit/26a3bd4838479a3690ede50a154bba033450cd11))
* Resolve DBConnection timeout errors in CI tests ([1e3dd63](https://github.com/georgeguimaraes/arcana/commit/1e3dd63750d0db8cf0b137f1ab2349d57c495b2d))
* Resolve NER serving race conditions and test isolation ([73510a1](https://github.com/georgeguimaraes/arcana/commit/73510a1c7187c3c704ac204a3aa96868f94a6aeb))
* Set minimum pool_size of 20 for CI environments ([035fdd6](https://github.com/georgeguimaraes/arcana/commit/035fdd631cd677a818ed21757b792f5eec9312cb))
* Show graph stats on collections page when data exists ([8a82559](https://github.com/georgeguimaraes/arcana/commit/8a82559a65c7ad477009094cc7058d7e4743f30f))
* Stabilize async tests with VACUUM on startup ([ab471da](https://github.com/georgeguimaraes/arcana/commit/ab471daad07c22c29e9561161c8b5c107bd3679d))
* Strengthen community summary prompt to prevent generic intros ([19d9c25](https://github.com/georgeguimaraes/arcana/commit/19d9c25ec181097d97c307992609ba9da5fe89d6))


### Miscellaneous

* add dependabot for daily dependency updates ([#11](https://github.com/georgeguimaraes/arcana/issues/11)) ([9ab9f70](https://github.com/georgeguimaraes/arcana/commit/9ab9f709de8a5c946a0cbf52caa8248f5bcc5974))
* **beads:** remove beads issue tracking system files ([6af715e](https://github.com/georgeguimaraes/arcana/commit/6af715e443c59c45cb4859afb780c51ba0bac7f8))
* **deps:** bump actions/cache from 3 to 5 ([#13](https://github.com/georgeguimaraes/arcana/issues/13)) ([2d649a9](https://github.com/georgeguimaraes/arcana/commit/2d649a984559854244dd0b72f219dfc336cc7c63))
* **deps:** bump actions/checkout from 4 to 6 ([#14](https://github.com/georgeguimaraes/arcana/issues/14)) ([315aefd](https://github.com/georgeguimaraes/arcana/commit/315aefd3c0fa34a6e1cc9d6af40ab1cc2fecf293))
* **deps:** bump amannn/action-semantic-pull-request from 5 to 6 ([#12](https://github.com/georgeguimaraes/arcana/issues/12)) ([7480a37](https://github.com/georgeguimaraes/arcana/commit/7480a37e77578c19afd5fbcbf259c9526d626c87))
* **deps:** use released stephen package from hex ([#16](https://github.com/georgeguimaraes/arcana/issues/16)) ([f8c1722](https://github.com/georgeguimaraes/arcana/commit/f8c1722cd3788a158479bab4757f7941da8651cd))
* Fix formatting and add Elixir 1.19/OTP 28 to test matrix ([ba4acb4](https://github.com/georgeguimaraes/arcana/commit/ba4acb49624a7a537ec6c95ca74ba0abe5b2b6fb))
* trigger release-please ([f75e54d](https://github.com/georgeguimaraes/arcana/commit/f75e54d2d8405dde7bc7bb38d0efb4d2eadf0e13))
* trigger release-please ([ba32722](https://github.com/georgeguimaraes/arcana/commit/ba3272202315a5475f9e96528b7deb4dfce9acc5))
* trigger release-please ([b03b4a7](https://github.com/georgeguimaraes/arcana/commit/b03b4a71e1869b235d3b63edd0a05dee3a333e0c))
* Update leidenfold to 0.3.2 ([fb364e2](https://github.com/georgeguimaraes/arcana/commit/fb364e271b36a54a11e42c83a4d85983443c5855))
* Use proper Elixir/OTP version matrix in CI ([56e5db6](https://github.com/georgeguimaraes/arcana/commit/56e5db61045ecacdfe11d46e07cbb17e57f24c5b))


### Documentation

* Add Maintenance Tasks section to GraphRAG guide ([61dae86](https://github.com/georgeguimaraes/arcana/commit/61dae860e9c32bd82c51399c1ae5f6a4054bf4d2))
* Add PDF parser configuration documentation ([c958e2f](https://github.com/georgeguimaraes/arcana/commit/c958e2f42d66a8ed38ed043c3057161911717a72))
* Update 'How it works' section with current architecture ([0f1d00a](https://github.com/georgeguimaraes/arcana/commit/0f1d00a4f07e20c1b5edd7d351cfd5970d27f2f0))
* Update arcana version to ~&gt; 1.0 ([6ea1fa7](https://github.com/georgeguimaraes/arcana/commit/6ea1fa746cf621e2881e28364b9a46f3ebe01d0b))


### Code Refactoring

* Fix credo issues in agent.ex ([b1f3ee2](https://github.com/georgeguimaraes/arcana/commit/b1f3ee2b68e33ff53ed718b63d430fb29674bbd5))
* Remove typespecs from codebase ([2c34f0d](https://github.com/georgeguimaraes/arcana/commit/2c34f0d514b09ea962d9b4fb6a897aab49ce04d1))
* Replace ex_leiden/leidenalg with leidenfold for community detection ([addef8d](https://github.com/georgeguimaraes/arcana/commit/addef8d1c90b23925600f428f45f4fe62068e55e))
* Use leidenfold native hierarchical detection ([70c4ed8](https://github.com/georgeguimaraes/arcana/commit/70c4ed8265b0df6923981c755e960653cfee1819))
* Use TaskSupervisor for dashboard async operations ([14de97f](https://github.com/georgeguimaraes/arcana/commit/14de97f8d69837db87e00a0848978daabfd9028d))


### Performance Improvements

* Optimize list_entities query with subqueries ([f343e51](https://github.com/georgeguimaraes/arcana/commit/f343e51ff3f6d6940158a77099fea154118d4bf4))

## [1.2.0](https://github.com/georgeguimaraes/arcana/compare/v1.1.0...v1.2.0) (2026-01-03)


### Features

* Add E5 embedding model prefix support ([8a0d8a5](https://github.com/georgeguimaraes/arcana/commit/8a0d8a52d6bada8d1472d9c258dfa1df2b93068f))
* Add GraphRAG (Graph-enhanced Retrieval Augmented Generation) ([#7](https://github.com/georgeguimaraes/arcana/issues/7)) ([4faca71](https://github.com/georgeguimaraes/arcana/commit/4faca71f390439b6774b7e84638bf4112f881dbe))
* Add swappable GraphStore backend ([#9](https://github.com/georgeguimaraes/arcana/issues/9)) ([42e7074](https://github.com/georgeguimaraes/arcana/commit/42e7074028c4c9e5269f68a6e49782e36a6adb87))
* Add swappable GraphStore issues from GitHub [#8](https://github.com/georgeguimaraes/arcana/issues/8) ([7adb131](https://github.com/georgeguimaraes/arcana/commit/7adb13193193ed022050ba8cadcf24a0f2ce413a))
* Add telemetry to GraphStore and VectorStore ([61f4f3d](https://github.com/georgeguimaraes/arcana/commit/61f4f3d5d7946df8501d5e4caf1e3dcceaea6ae9))
* Make Nx backend configurable (EXLA, EMLX, Torchx) ([#5](https://github.com/georgeguimaraes/arcana/issues/5)) ([86b8ef9](https://github.com/georgeguimaraes/arcana/commit/86b8ef9e251b8366fb62af0dba0165762ba07478))

## [1.1.0](https://github.com/georgeguimaraes/arcana/compare/v1.0.0...v1.1.0) (2026-01-01)


### Features

* Add pluggable Chunker behaviour for custom chunking strategies ([4452374](https://github.com/georgeguimaraes/arcana/commit/44523744ac2c177d4c6966e19e3e28971bf947af))
* Add release workflow with GitHub-generated notes ([7bf5568](https://github.com/georgeguimaraes/arcana/commit/7bf55681adb53773af4bd7d6843e236bfdfe5cfa))
* Add single-query hybrid search for pgvector backend ([97e86b2](https://github.com/georgeguimaraes/arcana/commit/97e86b2ba7c9e321021b6dc8b87a136892a67adf))


### Bug Fixes

* Add validations to Evaluation Run and TestCase changesets ([d1c0963](https://github.com/georgeguimaraes/arcana/commit/d1c0963f48767bb36baac0596ea9c3e8fa7daaa7))
* Consistent error handling across API ([7d246ea](https://github.com/georgeguimaraes/arcana/commit/7d246ea31882123734a7b89192d581aa011f670f))
* Extract global config tests to separate async: false module ([90293d4](https://github.com/georgeguimaraes/arcana/commit/90293d49bf8bace7778113c79b665fab760fe824))
* Make EmbedderTest async: false to prevent config races ([ccb47d7](https://github.com/georgeguimaraes/arcana/commit/ccb47d7f307ea7c4b0673af3abc3a603d080139f))
* Make evaluation run async to avoid blocking LiveView ([e2f0321](https://github.com/georgeguimaraes/arcana/commit/e2f0321fe2403c13acbf0e2484bc53aa230cb6b9))
* Make evaluation run async with supervised tasks ([19553ec](https://github.com/georgeguimaraes/arcana/commit/19553ecdd575f39d6a8238232b0d3a759440080a))
* Move DB queries from mount() to handle_params() in LiveViews ([c48d3bd](https://github.com/georgeguimaraes/arcana/commit/c48d3bd20cbeb056ece47c4dfd9d237fef4ee805))
* Resolve credo warnings for CI ([ecaf1bd](https://github.com/georgeguimaraes/arcana/commit/ecaf1bd6c9aefecc43412336cc0c01aa60ab23ef))
* Use plainto_tsquery for safe fulltext search input ([3379ff0](https://github.com/georgeguimaraes/arcana/commit/3379ff05d3d9c960590805e9b3813e2698dbba4d))
* Validate UUID format in Chunk changeset ([6481101](https://github.com/georgeguimaraes/arcana/commit/648110109cabaa57e2cb4e3e4525349ed32f959b))

## 1.0.0 (2025-12-30)


### Features

* Add Agent pipeline with context struct ([6e0f891](https://github.com/georgeguimaraes/arcana/commit/6e0f8912ca6a9bc3e29043d44b69a162265c9a2e))
* Add Agent.rewrite/2 and consistent :llm option across Agent functions ([efb2395](https://github.com/georgeguimaraes/arcana/commit/efb239500040c5387b77b38203e70d2f3bf5f606))
* Add Agentic Search tab to Dashboard ([88feac7](https://github.com/georgeguimaraes/arcana/commit/88feac78902dd6bfba9fea95312a3b28a268249e))
* Add Arcana brand text to stats ribbon ([1057866](https://github.com/georgeguimaraes/arcana/commit/1057866fa3907c0adb2c7a545857d57129d76acd))
* Add Arcana.Telemetry.Logger for easy telemetry logging ([6f3954e](https://github.com/georgeguimaraes/arcana/commit/6f3954e6688d3157d822c7465616a976665c55f0))
* Add behaviours for all Agent pipeline components ([e2355ac](https://github.com/georgeguimaraes/arcana/commit/e2355acd148b6de44d6e4dc2c291af6c21c1817d))
* Add collection filter for evaluation test case generation ([a416cb4](https://github.com/georgeguimaraes/arcana/commit/a416cb460b3617e9cd0f16957cac81f68ae27006))
* Add collection filter to Documents tab ([b441b8f](https://github.com/georgeguimaraes/arcana/commit/b441b8fb75470304f9e4e2b1490e95d3343ac909))
* Add collection option to Agent.search for explicit collection selection ([40b8a65](https://github.com/georgeguimaraes/arcana/commit/40b8a6556b7e883e882e925305f961eb4dbf12de))
* Add collection routing to Agent pipeline ([c46b699](https://github.com/georgeguimaraes/arcana/commit/c46b69939d9420d32d0127f09f582614717dd7dc))
* Add collections for document segmentation and file upload UI ([eccbb21](https://github.com/georgeguimaraes/arcana/commit/eccbb21bd6062467e27cd454af9070d4f9eada37))
* Add Collections tab to dashboard with CRUD operations ([7211760](https://github.com/georgeguimaraes/arcana/commit/721176005f31b6e133347731270f55efdfc08864))
* Add configurable embedding providers ([4f3aa93](https://github.com/georgeguimaraes/arcana/commit/4f3aa934178b28b113a382cc412d6f87ceeb6a49))
* Add configurable prompts to Agent and ask/2 ([42ea3b4](https://github.com/georgeguimaraes/arcana/commit/42ea3b4836373f6edfd8231ef91f9f3610f231fc))
* Add Document/Chunk schemas and mix arcana.install task ([bc48045](https://github.com/georgeguimaraes/arcana/commit/bc48045209ac13998674de8def9103919cc10f92))
* Add end-to-end answer evaluation with faithfulness scoring ([d14048a](https://github.com/georgeguimaraes/arcana/commit/d14048a9f1e1b45aee2db7a424d38d15b3e597c2))
* Add end-to-end tests for LLM integration ([d909b1c](https://github.com/georgeguimaraes/arcana/commit/d909b1c0cd5bed058c214c6e4f08a95857a398ed))
* Add foundation - Chunker and Embeddings with TDD ([6a3fb78](https://github.com/georgeguimaraes/arcana/commit/6a3fb783ad4b62238d512b93656a818bbf3345d2))
* Add fulltext search to VectorStore and wire all modes ([4ebc227](https://github.com/georgeguimaraes/arcana/commit/4ebc227ee188ec9c86a333c09be7923d594c75b5))
* Add generate test cases button to dashboard ([1d935f1](https://github.com/georgeguimaraes/arcana/commit/1d935f159e3c4e741eb45e4c9d01f6abafc1c043))
* Add hybrid search with vector + full-text fusion ([1801ea5](https://github.com/georgeguimaraes/arcana/commit/1801ea5b79938b57a660bc850ac2c794df53c99e))
* Add icons to action buttons in Documents and Collections pages ([14fa9e3](https://github.com/georgeguimaraes/arcana/commit/14fa9e3e7722fe5a8386b9d94b53a806ad5493f2))
* Add Igniter-powered installer for automatic setup ([7ffb03e](https://github.com/georgeguimaraes/arcana/commit/7ffb03e86389c2cbca8266a5fbd573dda8929ef6))
* Add in-memory vector store backend with HNSWLib ([f6ca251](https://github.com/georgeguimaraes/arcana/commit/f6ca251ff60d569bb768563ed9fd5a0e493f824f))
* Add Info tab to dashboard showing all configuration ([94ce4dc](https://github.com/georgeguimaraes/arcana/commit/94ce4dc91460b9737154207422e2d8e55db44e29))
* Add LiveView dashboard with purple theme ([c2967f1](https://github.com/georgeguimaraes/arcana/commit/c2967f14ad621c420e6bcea511cf12c7bcd7c810))
* Add LLM protocol for flexible LLM integration ([d0f7389](https://github.com/georgeguimaraes/arcana/commit/d0f7389d6aa91ec86dc57e285305e83867a9b573))
* Add macro-based router for embeddable dashboard ([1d1a5e0](https://github.com/georgeguimaraes/arcana/commit/1d1a5e0f37f63c36ee4ac067b0bb4d1990ccb9d6))
* Add multi-select collection filter to Ask and Search tabs ([aa64402](https://github.com/georgeguimaraes/arcana/commit/aa6440269c07da6e43b0ff788466b023a677dc3e))
* Add PDF and document file parsing ([dc59c30](https://github.com/georgeguimaraes/arcana/commit/dc59c30d48f1c8f256920ae1b049da2fb0c8916b))
* Add per-call :vector_store option for backend override ([2753525](https://github.com/georgeguimaraes/arcana/commit/27535250b1a22e3a95d863d136eb2f2ac41d446d))
* Add pluggable Selector behaviour for Agent.select ([2ea0a81](https://github.com/georgeguimaraes/arcana/commit/2ea0a81e9f1d8ee063856e0a1579424524fceb56))
* Add query expansion step to Agent pipeline ([993d5c2](https://github.com/georgeguimaraes/arcana/commit/993d5c2c655722e251135b3209894573ed5ab72a))
* Add query rewriting with LLM support ([5cc2ddb](https://github.com/georgeguimaraes/arcana/commit/5cc2ddb32d6f2b2b49e6da5a6e9d0f4b52072d05))
* Add question decomposition to Agent pipeline ([eef463b](https://github.com/georgeguimaraes/arcana/commit/eef463b03843f488c80faafe3a8ec9b36ca5c698))
* Add RAG pipeline with Arcana.ask/2 ([8853588](https://github.com/georgeguimaraes/arcana/commit/885358869bbad1dfa89ed6ee2c3f86bba5e9c0d1))
* Add re-ranking step to Agent pipeline ([4330ccf](https://github.com/georgeguimaraes/arcana/commit/4330ccf413956b4ab5c7f795d280f5f0f1bd52f4))
* Add reranker config to dashboard Info tab and EvaluationRun ([3b857f4](https://github.com/georgeguimaraes/arcana/commit/3b857f4b1a41a2ffb2369148f37afc3664f6b664))
* Add retrieval evaluation system ([342da85](https://github.com/georgeguimaraes/arcana/commit/342da8594194e050a2f64e4f830a0daa4f399346))
* Add rewriter helpers (expand, keywords, decompose) ([fc41ef8](https://github.com/georgeguimaraes/arcana/commit/fc41ef8d4556051d4823757114fccc72d854f5d7))
* Add self-correcting answers and consistent :llm option across Agent functions ([9d21572](https://github.com/georgeguimaraes/arcana/commit/9d2157246a9c653eba2407d4e88e7795cbd0038f))
* Add self-correcting search to Agent pipeline ([dd8d458](https://github.com/georgeguimaraes/arcana/commit/dd8d4581bdc37517ac50a0e890b91251da88d51a))
* Add Simple/Agentic mode toggle to Ask tab ([9f73a18](https://github.com/georgeguimaraes/arcana/commit/9f73a18eb82d2af080ed9da0a2c3d21a72b35357))
* Add stats, pagination, and document detail view to dashboard ([6d72c37](https://github.com/georgeguimaraes/arcana/commit/6d72c378c2d593566c6b00af1d2f7c542282aac6))
* Add telemetry events for observability ([4ea68af](https://github.com/georgeguimaraes/arcana/commit/4ea68afe72af0db57342432abe7160bae8f5e2cb))
* Add telemetry for LLM calls ([2bb449b](https://github.com/georgeguimaraes/arcana/commit/2bb449b87f47c90a4a1297d8125d21093ce5b5a3))
* Add tuple LLM config and improve ask return value ([28ffb00](https://github.com/georgeguimaraes/arcana/commit/28ffb005fe34ca6b95ff490b7ee0b6db4a0068ce))
* Add Z.ai embeddings and rename Embedding to Embedder ([9453241](https://github.com/georgeguimaraes/arcana/commit/9453241beed7ea9225aadf27777123ee3a2ebac7))
* Complete minimal RAG loop with public API ([bc11d49](https://github.com/georgeguimaraes/arcana/commit/bc11d490122f52c76892b30fd8ab7fe8bab7cfe8))
* Enhance dashboard with search modes and format options ([8211881](https://github.com/georgeguimaraes/arcana/commit/82118816d5163b19ec90f0c933d07c80f827edef))
* Improve query decomposition prompt ([5314506](https://github.com/georgeguimaraes/arcana/commit/5314506b0f684df91e800d6c0174d90e1f580e79))
* Improve query expansion prompt ([30c72c2](https://github.com/georgeguimaraes/arcana/commit/30c72c2c7affe9d708fd9149824239a3be59fc57))
* Include collection descriptions in select/2 prompt ([d7e9aa6](https://github.com/georgeguimaraes/arcana/commit/d7e9aa6878c932894945eb36e97446364cc4c62a))
* Make PDF support optional ([79bdcac](https://github.com/georgeguimaraes/arcana/commit/79bdcacdc6b05135707cdc7160807d7f25716cd0))
* Replace custom chunker with text_chunker library ([33657c5](https://github.com/georgeguimaraes/arcana/commit/33657c56547ff609739f476c3d12465bfa90ca36))
* Save Arcana config in evaluation runs ([3731f8f](https://github.com/georgeguimaraes/arcana/commit/3731f8f9951860c91ab136574b5e4551df406bc2))
* Support collection descriptions in ingest/2 ([f92d9d0](https://github.com/georgeguimaraes/arcana/commit/f92d9d0a4a98ec90f6d1895b0038a44cb6bbf334))
* Support custom module embedding implementations ([6af20a7](https://github.com/georgeguimaraes/arcana/commit/6af20a71fd661536028163e07893cce81864006c))
* Support provider_options passthrough for LLM calls ([51b05c9](https://github.com/georgeguimaraes/arcana/commit/51b05c9c8ec496ec79b08a450acc495411b5bc28))
* Use req_llm fork with Z.ai thinking parameter support ([f0b721e](https://github.com/georgeguimaraes/arcana/commit/f0b721eccceb93071d0d7c9810502b859a6fdd4a))


### Bug Fixes

* Add collections table to migration template ([6ae13e3](https://github.com/georgeguimaraes/arcana/commit/6ae13e3db3b330b84728e3cad3f44e20acd4db8d))
* Address credo warnings and code style issues ([89326c2](https://github.com/georgeguimaraes/arcana/commit/89326c26cdaee8e66742b0fe79d83e57556e4577))
* Align action buttons in documents table ([0a221e8](https://github.com/georgeguimaraes/arcana/commit/0a221e830233f59b9a7749fd72d5a242c5841288))
* Align Search tab collection CSS with Ask tab ([b5b4d95](https://github.com/georgeguimaraes/arcana/commit/b5b4d95089f8c39d25d35bf0a11e78ae24e63fee))
* Center icons in Actions column ([b77727e](https://github.com/georgeguimaraes/arcana/commit/b77727eb06664e5d28d0d4fe3e1ee996a7b50a5e))
* Correct name in LICENSE to match README ([f7dc44f](https://github.com/georgeguimaraes/arcana/commit/f7dc44f025065dcefa41a96b15e206f4ea0328eb))
* Filter out whitespace-only chunks during text splitting ([b9571cc](https://github.com/georgeguimaraes/arcana/commit/b9571cc2594676e8eca134aea2ea18a40590b257))
* Fix ask_live template and telemetry logger ([ead2638](https://github.com/georgeguimaraes/arcana/commit/ead26382cefe854af1972edd266092e724c23f23))
* Fix flaky tests and update README license format ([40c77d0](https://github.com/georgeguimaraes/arcana/commit/40c77d01e2782a704997e025627de7ef913f7e85))
* Improve document detail view styling consistency ([c94f42a](https://github.com/georgeguimaraes/arcana/commit/c94f42ab0c350bd312de4c82750b162aa4a5f196))
* Improve documents table styling ([68557b7](https://github.com/georgeguimaraes/arcana/commit/68557b7bc39ccd54845a89cce61b99b073e4176c))
* Include model metadata in telemetry stop events ([dff225c](https://github.com/georgeguimaraes/arcana/commit/dff225c9f53813894dd3fd5210a4ff5036d7f856))
* Install cmake in CI for hnswlib compilation ([ff9de44](https://github.com/georgeguimaraes/arcana/commit/ff9de44c071cc5f4d4079c10c0a2def1c812471d))
* Lower default chunk_size to 450 tokens for model safety margin ([a2ccd8c](https://github.com/georgeguimaraes/arcana/commit/a2ccd8cb79251a0ab1f384580a92ddc6da7e8c7b))
* Make Arcana brand text bigger and vertically centered ([7248784](https://github.com/georgeguimaraes/arcana/commit/72487845889d11a6529a8e32ab10bb1c1f9554ac))
* Make file upload dropzone clickable ([63801fc](https://github.com/georgeguimaraes/arcana/commit/63801fc662f987de254caf5ddb30a63df6b8fe8d))
* Move collection checkbox CSS to main style block ([3ba2a5d](https://github.com/georgeguimaraes/arcana/commit/3ba2a5ddd187fc7e86638150e99f1fae07e4121b))
* Prefix unused variables with underscore in tests ([5311878](https://github.com/georgeguimaraes/arcana/commit/531187834baa49cebd4804438292a9d159cec4b7))
* Redact sensitive keys (api_key, token, etc.) in Info page ([ba2070a](https://github.com/georgeguimaraes/arcana/commit/ba2070a76cc46a187940f7196e98545f3ae96e64))
* Remove arcana-actions class to fix button alignment ([0092605](https://github.com/georgeguimaraes/arcana/commit/00926050319b8aeed812314e645b0315fb2afa22))
* Remove borders from Documents page icon buttons ([d8486cf](https://github.com/georgeguimaraes/arcana/commit/d8486cfa7b3b598f6974f527975259185bdf3200))
* Remove elixir_make override and update hnswlib ([deba0cf](https://github.com/georgeguimaraes/arcana/commit/deba0cf6e5fc5aa987df8d656614eb0a1e7e1c25))
* Set MIX_ENV=test for CI database setup ([ac1d5f0](https://github.com/georgeguimaraes/arcana/commit/ac1d5f0e4317205e70e4748d76aa8c2216ecc53b))
* Specify postgres user in CI health check ([dedfb77](https://github.com/georgeguimaraes/arcana/commit/dedfb7724e9c343f7814dbf6a9c98b1dc8bf8495))
* Start host app in mix arcana.reembed task ([baf5678](https://github.com/georgeguimaraes/arcana/commit/baf56789d0b0fafaac38a3c9a66334d7395ea5ee))
* Trim leading/trailing whitespace from LLM answers ([74aa858](https://github.com/georgeguimaraes/arcana/commit/74aa8583d823241a63c7798c19fea2d3ccb1d5ba))
* Update arcana.install to use correct Embedding.Local module ([d22c28a](https://github.com/georgeguimaraes/arcana/commit/d22c28a674b8b0710aabf3ba8f79044373be99c5))
* Use apply/3 for optional dependencies to avoid compile warnings ([fe9ab70](https://github.com/georgeguimaraes/arcana/commit/fe9ab70c5cb54b0546c37b0b561f2fdf1872145b))
* Use async: false for telemetry tests ([09c4ffa](https://github.com/georgeguimaraes/arcana/commit/09c4ffac5563d41f76e198fbf5579abfc9d585b7))
* Use text-align for Actions column centering ([8dd7340](https://github.com/georgeguimaraes/arcana/commit/8dd7340cbf5a8958681034816d74a3f5e98e77c6))
* Use trash icon for delete button in test cases list ([e81ea5b](https://github.com/georgeguimaraes/arcana/commit/e81ea5b0b9d3172a1588db7ea17941b687b46958))

## [0.1.0] - 2025-01-01

### Added

- Core RAG API: `ingest/2`, `search/2`, `ask/2`, `delete/2`
- Agentic RAG pipeline with `Arcana.Agent`:
  - `rewrite/2` - Clean up conversational input
  - `select/2` - LLM-based collection selection
  - `expand/2` - Query expansion with synonyms
  - `decompose/2` - Multi-part question decomposition
  - `search/2` - Vector search across collections
  - `rerank/2` - LLM-based relevance scoring
  - `answer/2` - Answer generation with self-correction
- Pluggable components via behaviours for all pipeline steps
- Embedding providers:
  - Local Bumblebee (default, no API keys)
  - OpenAI
  - Custom via `Arcana.Embedder` behaviour
- Vector store backends:
  - pgvector (default)
  - In-memory HNSWLib
  - Custom via `Arcana.VectorStore` behaviour
- Search modes: semantic, fulltext, hybrid (RRF fusion)
- File ingestion: text, markdown, PDF
- Collections for document segmentation
- Evaluation system with MRR, Recall, Precision, Hit Rate metrics
- LiveView dashboard for document management and search
- Telemetry events for observability
- Igniter installer for streamlined setup
