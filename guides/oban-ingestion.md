# Ingestion with Oban

Ingestion is CPU- and IO-heavy (chunking, embedding, optional graph
extraction), so production apps usually run it in the background. This
recipe wraps `Arcana.ingest/2` in an [Oban](https://hexdocs.pm/oban) worker
with the properties a multi-tenant ingestion pipeline needs:

- a dedicated queue so ingestion can't starve your other workers
- uniqueness on the document identity while jobs wait in the queue, so
  redundant work collapses before it starts
- replace-args-while-queued, so when content changes faster than the queue
  drains, the latest version wins
- `replace: true` so re-ingesting an identity supersedes the previous
  document atomically (old chunks stay searchable until the new ingest
  completes)

## The worker

```elixir
defmodule MyApp.IngestWorker do
  use Oban.Worker,
    queue: :ingest,
    max_attempts: 3,
    unique: [
      # One job per document identity while it waits in the queue.
      # Deliberately NOT including :executing: replacing args on a job
      # that is already running does nothing (the worker read its args
      # at start), so the new content would be silently lost. A
      # duplicate arriving mid-execution becomes a fresh job instead,
      # which runs afterwards and supersedes via replace: true.
      fields: [:worker, :args],
      keys: [:collection, :source_id],
      states: [:available, :scheduled, :retryable],
      # When a duplicate arrives while a job is still queued, keep the
      # job but swap in the newest args, so the latest content wins.
      on_conflict: {:replace, [:args]}
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"collection" => collection, "source_id" => source_id, "content" => content} = args

    case Arcana.ingest(content,
           repo: MyApp.Repo,
           collection: collection,
           source_id: source_id,
           replace: true,
           metadata: Map.get(args, "metadata", %{})
         ) do
      {:ok, _document} -> :ok
      # A concurrent ingest for the same identity finished first and
      # superseded this one: the newest content already won, so don't retry.
      {:error, :replaced_by_concurrent_ingest} -> {:cancel, :superseded}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

Enqueue from wherever content arrives:

```elixir
%{collection: "tenant-#{tenant.id}", source_id: "doc-#{doc.id}", content: text}
|> MyApp.IngestWorker.new()
|> Oban.insert()
```

## Queue configuration

Give ingestion its own queue with a limit matched to your embedder. The
local Bumblebee embedder batches on the serving, so a few concurrent jobs
keep the batch full without oversubscribing:

```elixir
# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, ingest: 4]
```

For API-based embedders, size the limit against the provider's rate limit
instead.

## Notes

- `replace: true` requires a `:source_id`; treat it as the document's
  stable identity per collection. Without `replace`, re-enqueuing the same
  identity accumulates duplicate documents.
- With `config :arcana, strict_collections: true`, create the collection
  before the first job runs (`Arcana.Collection.get_or_create/3`), or
  ingest returns `{:error, {:unknown_collection, name}}` and the job
  retries pointlessly.
- Files work the same way through `Arcana.ingest_file/2`; for uploads that
  live in object storage, download to a tmp path in the worker first.
- The Oban uniqueness lock and Arcana's replace advisory lock are
  complementary: uniqueness collapses redundant work before it starts,
  the advisory lock makes whatever does run correct under races.
- Ordering caveat: if two jobs for the same identity ever execute
  concurrently (the second enqueued after the first started), Arcana's
  swap is first-to-complete-wins, not latest-wins. If your content
  churns faster than ingestion completes and strict latest-wins
  matters, run the ingest queue with `limit: 1`, or have the worker
  `{:snooze, n}` when an earlier job for the same identity is still
  executing.
