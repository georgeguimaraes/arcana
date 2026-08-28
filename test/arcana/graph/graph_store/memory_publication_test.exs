defmodule Arcana.Graph.GraphStore.MemoryPublicationTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Graph.GraphStore.Memory

  setup do
    {:ok, pid} = Memory.start_link([])

    {:ok, collection} =
      Collection.get_or_create("memory-publication-#{System.unique_integer()}", Repo)

    completed = create_document(collection, :completed)
    failed = create_document(collection, :failed)

    %{
      pid: pid,
      collection: collection,
      anchor: create_chunk(completed, "published anchors"),
      edge: create_chunk(completed, "published edge"),
      failed: create_chunk(failed, "failed edge")
    }
  end

  test "publication-facing reads expose only completed chunk evidence", ctx do
    entities = [
      %{name: "Alice", type: "person"},
      %{name: "Bob", type: "person"},
      %{name: "Charlie", type: "person"}
    ]

    {:ok, ids} = Memory.persist_entities(ctx.collection.id, entities, pid: ctx.pid)

    :ok =
      Memory.persist_mentions(
        [
          %{entity_name: "Alice", chunk_id: ctx.anchor.id},
          %{entity_name: "Bob", chunk_id: ctx.anchor.id},
          %{entity_name: "Alice", chunk_id: ctx.failed.id},
          %{entity_name: "Charlie", chunk_id: ctx.failed.id}
        ],
        ids,
        pid: ctx.pid
      )

    fact = [%{source: "Alice", target: "Bob", type: "knows"}]
    :ok = Memory.persist_relationships(ctx.failed.id, fact, ids, pid: ctx.pid)

    opts = [pid: ctx.pid, repo: Repo]

    assert [%{chunk_id: chunk_id}] = Memory.search(["Alice"], [ctx.collection.id], opts)
    assert chunk_id == ctx.anchor.id

    assert Enum.map(Memory.find_entities(ctx.collection.id, opts), & &1.name) |> Enum.sort() ==
             ["Alice", "Bob"]

    assert {:error, :not_found} = Memory.get_entity(ids["charlie"], opts)
    assert [%{chunk_id: anchor_id}] = Memory.get_mentions(ids["alice"], opts)
    assert anchor_id == ctx.anchor.id
    assert Memory.get_relationships(ids["alice"], opts) == []

    :ok = Memory.persist_relationships(ctx.edge.id, fact, ids, pid: ctx.pid)
    assert [relationship] = Memory.get_relationships(ids["alice"], opts)

    :ok =
      Memory.persist_communities(
        ctx.collection.id,
        [
          %{
            id: "community",
            level: 0,
            summary: "Alice knows Bob",
            entity_ids: [ids["alice"], ids["bob"]],
            dirty: false
          }
        ],
        pid: ctx.pid
      )

    :ok = Memory.delete_by_chunks([ctx.edge.id], opts)

    assert {:error, :not_found} = Memory.get_relationship(relationship.id, opts)
    assert {:ok, community} = Memory.get_community("community", opts)
    assert community.dirty
    assert community.entity_ids == [ids["alice"], ids["bob"]]
    assert Memory.get_community_summaries(ctx.collection.id, opts) == []
  end

  test "deleting failed-only relationship evidence keeps communities clean", ctx do
    entities = [%{name: "Alice", type: "person"}, %{name: "Bob", type: "person"}]
    {:ok, ids} = Memory.persist_entities(ctx.collection.id, entities, pid: ctx.pid)

    :ok =
      Memory.persist_mentions(
        [
          %{entity_name: "Alice", chunk_id: ctx.anchor.id},
          %{entity_name: "Bob", chunk_id: ctx.anchor.id}
        ],
        ids,
        pid: ctx.pid
      )

    :ok =
      Memory.persist_relationships(
        ctx.failed.id,
        [%{source: "Alice", target: "Bob", type: "knows"}],
        ids,
        pid: ctx.pid
      )

    :ok =
      Memory.persist_communities(
        ctx.collection.id,
        [
          %{
            id: "community",
            level: 0,
            summary: "Alice and Bob",
            entity_ids: [ids["alice"], ids["bob"]],
            dirty: false
          }
        ],
        pid: ctx.pid
      )

    :ok = Memory.delete_by_chunks([ctx.failed.id], pid: ctx.pid, repo: Repo)

    assert {:ok, community} = Memory.get_community("community", pid: ctx.pid)
    refute community.dirty
  end

  test "Arcana.delete preserves removed publication evidence for external memory cleanup", ctx do
    entity_extractor = fn _text, _opts ->
      {:ok, [%{name: "Alice", type: "person"}, %{name: "Bob", type: "person"}]}
    end

    relationship_extractor = fn text, _entities, _opts ->
      if text =~ "edge" do
        {:ok, [%{source: "Alice", target: "Bob", type: "knows"}]}
      else
        {:ok, []}
      end
    end

    opts = [
      repo: Repo,
      graph: true,
      graph_store: {Memory, pid: ctx.pid},
      entity_extractor: entity_extractor,
      relationship_extractor: relationship_extractor,
      collection: ctx.collection.name
    ]

    {:ok, edge_document} = Arcana.ingest("published edge", opts)
    {:ok, _anchor_document} = Arcana.ingest("published anchor", opts)

    [alice, bob] =
      ctx.collection.id
      |> Memory.find_entities(pid: ctx.pid, repo: Repo)
      |> Enum.sort_by(& &1.name)

    :ok =
      Memory.persist_communities(
        ctx.collection.id,
        [
          %{
            id: "delete-community",
            level: 0,
            summary: "Alice knows Bob",
            entity_ids: [alice.id, bob.id],
            dirty: false
          }
        ],
        pid: ctx.pid
      )

    # The wrapper returns a stale :processing copy from Arcana.delete/2's
    # initial lookup while the locked transaction reload sees the real
    # :completed row. This deterministically models completion winning the
    # race immediately before deletion acquires its row lock.
    delete_opts = Keyword.put(opts, :repo, Arcana.StaleDocumentStatusRepo)
    assert :ok = Arcana.delete(edge_document.id, delete_opts)

    assert Enum.map(Memory.find_entities(ctx.collection.id, pid: ctx.pid, repo: Repo), & &1.name)
           |> Enum.sort() == ["Alice", "Bob"]

    assert {:ok, community} = Memory.get_community("delete-community", pid: ctx.pid)
    assert community.dirty
  end

  defp create_document(collection, status) do
    %Document{}
    |> Document.changeset(%{
      content: "#{status} document",
      collection_id: collection.id,
      status: status
    })
    |> Repo.insert!()
  end

  defp create_chunk(document, text) do
    %Chunk{}
    |> Chunk.changeset(%{
      text: text,
      document_id: document.id,
      embedding: Enum.map(1..384, fn _ -> 0.0 end)
    })
    |> Repo.insert!()
  end
end
