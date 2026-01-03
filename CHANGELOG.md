# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
