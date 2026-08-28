# Upgrading to Arcana 4.0

Arcana 4.0 makes collection scope, publication, and graph provenance explicit.
The upgrade is mostly an API change for core-only installs. GraphRAG installs
also need a schema migration and a graph rebuild because relationships written
before 4.0 do not record which chunks support them.

## Before you start

Back up the database if you use GraphRAG. Graph schema v2 cannot be rolled back
to v1, and its migration intentionally deletes legacy relationship rows whose
source chunks cannot be reconstructed.

Update the dependency as usual:

```elixir
{:arcana, "~> 4.0"}
```

Arcana's core schema stays at version 1 in this release. An application already
running 3.0.1 should have adopted that version during its 3.0 upgrade, so it
does not need another core migration. You can confirm the recorded version in
application code or a non-interactive script:

```elixir
Arcana.Migration.recorded_version(MyApp.Repo)
# => 1

# Use the install's prefix when it has one
Arcana.Migration.recorded_version(MyApp.Repo, prefix: "arcana")
# => 1
```

If this returns `0`, finish the 3.0 core migration described by
`Arcana.Migration` before deploying 4.0.

## Use one collection scope

Every public read now takes the singular `:collection` option. It accepts
`:all`, one collection name, a list of names, or an empty list that matches
nothing:

```elixir
Arcana.search("refunds", collection: :all)
Arcana.search("refunds", collection: "support")
Arcana.search("refunds", collection: ["support", "api"])
Arcana.search("refunds", collection: [])
```

Change calls such as:

```elixir
# Arcana 3.x
Arcana.search("refunds", collections: ["support", "api"])

# Arcana 4.0
Arcana.search("refunds", collection: ["support", "api"])
```

Sweep `Arcana.search/2`, `Arcana.ask/2`, `Pipeline.search/2`, `Loop.new/2`,
document reads, evaluation operations, maintenance operations, and dashboard
mounts. They all use the same option now.

The removed `collections:` option raises. This is deliberate so an outdated
scoped call cannot silently become an unscoped read. Unknown collection names
match nothing when strict mode is off. With `strict_collections: true`, they
still return `{:error, {:unknown_collection, name}}`.

`Pipeline.select(collections: names)` stays plural. That option is the list of
candidates the selection step may choose from, not a retrieval scope.

The public `Arcana.Loop.Context.collections` and
`Arcana.Pipeline.Context.collections` fields can now contain `:all` for an
unrestricted scope. Arcana 3.x used `[nil]` in the Loop context. Update custom
tools and other context consumers that assume this field is always a list.

The dashboard router follows the same naming:

```elixir
# Arcana 3.x
arcana_dashboard "/arcana",
  collections: {MyAppWeb.ArcanaAccess, :allowed_collections}

# Arcana 4.0
arcana_dashboard "/arcana",
  collection: {MyAppWeb.ArcanaAccess, :allowed_collections}
```

The callback may return `:all`, one name, a list of names, or `[]`. See the
[Dashboard guide](dashboard.md) for the authorization and session lifetime
details.

## Update custom backends

The built-in memory vector store now enforces one embedding dimension per
server. A write with a different dimension returns:

```elixir
{:error, {:dimension_mismatch, expected: expected, actual: actual}}
```

A search with the wrong dimension returns no results. Start a separate memory
store when different collections use different embedding dimensions.

The rest of this section only applies to custom backends.

Custom `Arcana.Searcher` implementations now receive `:all` for a corpus-wide
read. Search once across the corpus and apply the requested ranking and limit
globally. Running one limited query per collection and concatenating the
results produces a different ranking.

Custom `Arcana.VectorStore.search/3` and `search_text/3` implementations receive
either one collection name or `:all`. They must also rank and limit `:all`
globally. An unknown collection name must return an empty result rather than
treating it as unscoped.

Custom `Arcana.Graph.GraphStore` implementations have three contract changes:

  * Change `persist_relationships(relationships, entity_id_map, opts)` to
    `persist_relationships(chunk_id, relationships, entity_id_map, opts)` and
    store that chunk as evidence for each canonical relationship
  * Implement `with_write_lock(collection_id, opts, fun)`. It must provide
    mutual exclusion per collection across persistence, deletion, and
    replacement for every reference to the same backend instance
  * Keep `delete_by_chunks/2` idempotent. Cleanup may replay chunk IDs after the
    database delete has committed. Use `:collection_id` and
    `:published_chunk_ids` from the options when the deleted rows can no longer
    provide that context

`sweep_orphans/2` is still optional. Read the behaviour docs for
`Arcana.Searcher`, `Arcana.VectorStore`, and `Arcana.Graph.GraphStore` for the
complete contracts.

## Upgrade GraphRAG to schema v2

Skip this section if GraphRAG is not installed.

Pause ingestion, replacement, deletion, and graph maintenance during this
upgrade. Arcana 3.x graph writers do not produce the fingerprints or evidence
rows that schema v2 requires, so a mixed 3.x and 4.0 deployment is unsafe.

Add a host migration that delegates to Arcana. Use the same embedding dimension
and Postgres prefix as the existing GraphRAG install:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeArcanaGraphToV2 do
  use Ecto.Migration

  def up do
    Arcana.Graph.Migration.up(dimensions: 384)
  end

  def down do
    raise "Arcana graph schema v2 requires restoring the pre-upgrade backup"
  end
end
```

For a prefixed install, pass the same prefix:

```elixir
Arcana.Graph.Migration.up(dimensions: 384, prefix: "arcana")
```

Run the migration and deploy Arcana 4.0 as one maintenance operation:

```bash
mix ecto.migrate
```

Version 2 adds a fingerprint to each canonical relationship and an
`arcana_graph_relationship_evidence` table linking relationships to their
supporting chunks. The migration verifies the new schema before deleting the
legacy relationships, records v2 in the same transaction, preserves entities
and mentions, and marks existing community summaries dirty.

Rebuild the full graph after the migration:

```bash
mix arcana.graph.rebuild
```

Do not pass `--resume`. Existing mentions can make resume mode skip chunks that
still need their relationships rebuilt.

If the application uses communities, recreate and summarize them after the
graph rebuild:

```bash
mix arcana.graph.detect_communities
mix arcana.graph.summarize_communities --force
```

The [GraphRAG guide](graphrag.md) documents collection-specific forms and the
configuration each maintenance command uses.

You can verify the migration from application code or a non-interactive
script:

```elixir
Arcana.Graph.Migration.recorded_version(MyApp.Repo)
# => 2

# Use the install's prefix when it has one
Arcana.Graph.Migration.recorded_version(MyApp.Repo, prefix: "arcana")
# => 2
```

Before resuming traffic, smoke-test the boundaries the migration changed:

  * search a known collection and confirm the expected completed document is
    returned
  * confirm an unknown collection and `collection: []` both return no results
  * confirm pending, processing, and failed documents do not appear in search
  * confirm the graph rebuild produced the expected relationship count
  * if the dashboard is restricted, confirm a request containing any
    unauthorized collection is rejected rather than partially accepted

## Account for publication semantics

Only completed documents are published in 4.0. Pending, processing, and failed
documents no longer contribute to:

  * vector, keyword, hybrid, or graph retrieval
  * sparse `get_document_metadata/2` reads and evaluation generation
  * graph entities, relationships, communities, or traversal
  * graph statistics in the dashboard

Administrative document APIs can still list non-completed documents by status,
graph rebuild still processes every chunk selected for rebuilding, and the
dashboard's document and chunk totals still include operational states. If
application code queried Arcana's schemas directly and expected unpublished
rows in retrieval, keep that operational query separate from user-facing
retrieval.

## Update delete handling

`Arcana.delete/2` now matches its documented error-tuple contract more closely.
Callers should handle `{:error, reason}` rather than assuming every failure
raises.

For the Ecto graph store, a standalone call runs the document delete and graph
cleanup in one transaction. `{:error, {:sweep_failed, reason}}` leaves the
document in place, so retry the full delete. Inside a transaction owned by the
caller, the delete remains in that transaction's scope and the caller decides
whether to roll it back.

Any non-Ecto graph store, including the built-in `:memory` store, is cleaned
after the database commit and can return:

```elixir
{:error, {:post_commit_graph_cleanup_failed, context}}
```

The context includes `:chunk_ids`, `:published_chunk_ids`, and
`:collection_id`. Use those values to retry the idempotent graph cleanup. An
non-Ecto graph store cannot be cleaned safely when `Arcana.delete/2` is called
inside an existing Ecto transaction, so that case returns
`{:error, :external_graph_store_requires_post_commit_delete}`.

`replace: true` ingestion has the same post-commit cleanup error. In that case,
the replacement is already published and the graph cleanup should be retried
with the returned context.

## Rollback

Application code can roll back to 3.x only while the database remains on graph
schema v1. Once GraphRAG has migrated to v2, Arcana refuses a v2 to v1 schema
rollback because dropping the evidence table would destroy the information
needed to reconstruct v2 later.

Restore the pre-upgrade database backup to roll back the release. Calling
`Arcana.Graph.Migration.down(version: 0)` is an uninstall that removes all
Arcana graph tables, not a rollback to the 3.x graph schema.
