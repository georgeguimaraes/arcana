defmodule Arcana.Graph.GraphStore.EctoTest do
  use Arcana.DataCase, async: true

  alias Arcana.{Chunk, Collection, Document}
  alias Arcana.Graph.{Entity, EntityMention, EntityName, Relationship}
  alias Arcana.Graph.GraphStore.Ecto, as: EctoStore

  defp create_collection(name \\ "test-collection") do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp create_document(collection, title \\ "test-doc") do
    %Document{}
    |> Document.changeset(%{
      title: title,
      source: "test",
      content: "Test document content",
      collection_id: collection.id,
      status: :completed
    })
    |> Repo.insert!()
  end

  defp create_chunk(document, text \\ "test content") do
    %Chunk{}
    |> Chunk.changeset(%{
      text: text,
      document_id: document.id,
      embedding: Enum.map(1..384, fn _ -> :rand.uniform() end)
    })
    |> Repo.insert!()
  end

  defp create_entity(collection, name, type \\ "person") do
    %Entity{}
    |> Entity.changeset(%{
      name: name,
      type: type,
      collection_id: collection.id
    })
    |> Repo.insert!()
  end

  defp count_entities(collection) do
    Repo.aggregate(from(e in Entity, where: e.collection_id == ^collection.id), :count)
  end

  # One count per entity row in the collection, sorted, so a row left with
  # no mentions shows up as a 0 instead of being averaged away.
  defp mention_counts(collection) do
    Repo.all(
      from(e in Entity,
        left_join: m in EntityMention,
        on: m.entity_id == e.id,
        where: e.collection_id == ^collection.id,
        group_by: e.id,
        select: count(m.id)
      )
    )
    |> Enum.sort()
  end

  defp create_mention(entity, chunk) do
    %EntityMention{}
    |> EntityMention.changeset(%{
      entity_id: entity.id,
      chunk_id: chunk.id
    })
    |> Repo.insert!()
  end

  describe "delete_by_chunks/2" do
    test "sweeps orphans only in the collections those chunks belonged to" do
      # The sweep used to run across every collection in the database, so a
      # delete in one tenant could remove another tenant's entities.
      mine = create_collection("dbc-mine-#{System.unique_integer([:positive])}")
      theirs = create_collection("dbc-theirs-#{System.unique_integer([:positive])}")

      my_chunk = mine |> create_document() |> create_chunk()
      their_chunk = theirs |> create_document() |> create_chunk()

      my_entity = create_entity(mine, "Mine")
      their_entity = create_entity(theirs, "Theirs")

      create_mention(my_entity, my_chunk)
      create_mention(their_entity, their_chunk)

      # An orphan in the other collection: nothing references it, so a global
      # sweep would take it even though its chunks were never touched.
      their_orphan = create_entity(theirs, "TheirOrphan")

      assert :ok = EctoStore.delete_by_chunks([my_chunk.id], repo: Repo)

      refute Repo.get(Entity, my_entity.id), "the orphan in the target collection should go"
      assert Repo.get(Entity, their_entity.id), "another collection's entity must survive"

      assert Repo.get(Entity, their_orphan.id),
             "another collection's orphan is not this delete's business"
    end

    test "keeps an entity that still has mentions elsewhere" do
      collection = create_collection("dbc-keep-#{System.unique_integer([:positive])}")
      document = create_document(collection)
      deleted = create_chunk(document, "goes away")
      kept = create_chunk(document, "stays")

      entity = create_entity(collection, "Shared")
      create_mention(entity, deleted)
      create_mention(entity, kept)

      assert :ok = EctoStore.delete_by_chunks([deleted.id], repo: Repo)

      assert Repo.get(Entity, entity.id), "still mentioned by another chunk"
    end

    test "sweeps an orphan that belongs to no collection" do
      # The global sweep this replaced covered collection-less entities.
      # A per-collection sweep structurally cannot, so they need their own
      # pass or they leak forever.
      collection = create_collection("dbc-nullcoll-#{System.unique_integer([:positive])}")
      chunk = collection |> create_document() |> create_chunk()

      uncollected =
        %Entity{}
        |> Entity.changeset(%{name: "Stray", type: "person"})
        |> Repo.insert!()

      assert is_nil(uncollected.collection_id), "precondition: no collection"

      create_mention(uncollected, chunk)

      assert :ok = EctoStore.delete_by_chunks([chunk.id], repo: Repo)

      refute Repo.get(Entity, uncollected.id),
             "a collection-less entity with no mentions left has to go too"
    end

    test "keeps a collection-less entity that is still mentioned" do
      collection = create_collection("dbc-nullkeep-#{System.unique_integer([:positive])}")
      document = create_document(collection)
      deleted = create_chunk(document, "goes away")
      kept = create_chunk(document, "stays")

      uncollected =
        %Entity{}
        |> Entity.changeset(%{name: "StrayKept", type: "person"})
        |> Repo.insert!()

      create_mention(uncollected, deleted)
      create_mention(uncollected, kept)

      assert :ok = EctoStore.delete_by_chunks([deleted.id], repo: Repo)

      assert Repo.get(Entity, uncollected.id), "still mentioned by another chunk"
    end

    test "an empty list touches nothing" do
      collection = create_collection("dbc-empty-#{System.unique_integer([:positive])}")
      chunk = collection |> create_document() |> create_chunk()
      entity = create_entity(collection, "Untouched")
      create_mention(entity, chunk)

      assert :ok = EctoStore.delete_by_chunks([], repo: Repo)

      assert Repo.get(Entity, entity.id)
    end
  end

  describe "persist_entities/3" do
    test "inserts new entities and returns id map" do
      collection = create_collection()

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Bob", type: "person"}
      ]

      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      # The map is keyed both ways: {:raw, name} resolves a name to the row
      # Postgres actually put it in, the bare normalized key is the
      # cross-call fallback. See persist_entities/3.
      assert Map.has_key?(id_map, "alice")
      assert Map.has_key?(id_map, "bob")
      assert Map.has_key?(id_map, {:raw, "Alice"})
      assert Map.has_key?(id_map, {:raw, "Bob"})
      assert id_map[{:raw, "Alice"}] == id_map["alice"]
      assert id_map |> Map.values() |> Enum.uniq() |> length() == 2

      # Verify entities exist in DB
      assert Repo.get_by(Entity, name: "Alice", collection_id: collection.id)
      assert Repo.get_by(Entity, name: "Bob", collection_id: collection.id)
    end

    test "deduplicates entities by name" do
      collection = create_collection()

      entities = [
        %{name: "Alice", type: "person"},
        %{name: "Alice", type: "person"}
      ]

      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert id_map |> Map.values() |> Enum.uniq() |> length() == 1
      assert count_entities(collection) == 1
    end

    test "returns existing entity ids on upsert" do
      collection = create_collection()
      existing = create_entity(collection, "Alice", "person")

      entities = [%{name: "Alice", type: "person"}]
      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert id_map["alice"] == existing.id
    end

    test "upserts name variants into the same entity" do
      collection = create_collection()
      existing = create_entity(collection, "Two_Year_Limited_Warranty", "concept")

      entities = [%{name: "two year limited warranty", type: "concept"}]
      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)

      assert id_map["two year limited warranty"] == existing.id
      assert Repo.aggregate(Entity, :count) == 1

      # First-seen display name is kept
      assert Repo.get(Entity, existing.id).name == "Two_Year_Limited_Warranty"
    end

    # Elixir's String.downcase/trim and Postgres' lower/btrim disagree on
    # these three, so an entity used to miss ITSELF on the second upsert,
    # re-insert its own raw name and trip the (name, collection_id) unique
    # index. NBSP in particular arrives with any HTML/PDF-derived text.
    for {label, name} <- [
          {"trailing NBSP", "Delivery "},
          {"mid-string thin space", "Acme Corp"},
          {"turkish dotted capital I", "İstanbul"}
        ] do
      test "upserts an entity into itself when the name carries a #{label}" do
        collection = create_collection()
        name = unquote(name)

        {:ok, _} =
          EctoStore.persist_entities(collection.id, [%{name: name, type: "concept"}], repo: Repo)

        {:ok, _} =
          EctoStore.persist_entities(collection.id, [%{name: name, type: "concept"}], repo: Repo)

        assert Repo.aggregate(from(e in Entity, where: e.collection_id == ^collection.id), :count) ==
                 1
      end
    end

    # Distinct spellings that must land on ONE row. Mirrors the pairs
    # asserted in MemoryTest: the two backends have to agree about which
    # names are the same entity, or the same document builds a different
    # graph depending on the store.
    for {label, first, second} <- [
          {"trailing NBSP", "Delivery\u{a0}", "Delivery"},
          {"mid-string NBSP", "Acme\u{a0}Corp", "Acme Corp"},
          {"mid-string thin space", "Acme\u{2009}Corp", "Acme Corp"},
          {"mid-string ideographic space", "Acme\u{3000}Corp", "Acme Corp"}
        ] do
      test "treats a #{label} as the same entity as a plain space" do
        collection = create_collection()

        for name <- [unquote(first), unquote(second)] do
          {:ok, _} =
            EctoStore.persist_entities(collection.id, [%{name: name, type: "concept"}],
              repo: Repo
            )
        end

        assert Repo.aggregate(from(e in Entity, where: e.collection_id == ^collection.id), :count) ==
                 1
      end
    end

    # Known, documented divergence from the Memory store, which keeps these
    # two apart: Postgres' lower() folds U+0130 to a bare "i" while Elixir's
    # String.downcase/1 decomposes it into "i" plus a combining dot. Neither
    # backend applies canonical (NFC/NFD) normalization either.
    # See Arcana.Graph.EntityName.
    test "collapses a Turkish dotted capital I, unlike the Memory store" do
      collection = create_collection()

      for name <- ["İstanbul", "istanbul"] do
        {:ok, _} =
          EctoStore.persist_entities(collection.id, [%{name: name, type: "place"}], repo: Repo)
      end

      assert Repo.aggregate(from(e in Entity, where: e.collection_id == ^collection.id), :count) ==
               1
    end

    # Postgres decides which rows exist, so the in-call dedup must not
    # decide it too. These two spellings share an Elixir dedup key
    # (String.downcase/1 decomposes U+0130 into exactly the second one) but
    # not a Postgres one (lower() folds U+0130 to a bare "i"), so deduping
    # on the Elixir key collapsed them when they arrived in one chunk and
    # kept them apart when they arrived in two: same document, different
    # :chunk_size, different graph.
    test "keeps entity identity out of the hands of chunking" do
      decomposed = "i" <> <<0x307::utf8>> <> "stanbul"
      names = ["İstanbul", decomposed]

      assert String.downcase("İstanbul") == decomposed

      one_chunk = create_collection("one-chunk")

      {:ok, _} =
        EctoStore.persist_entities(
          one_chunk.id,
          Enum.map(names, &%{name: &1, type: "place"}),
          repo: Repo
        )

      two_chunks = create_collection("two-chunks")

      for name <- names do
        {:ok, _} =
          EctoStore.persist_entities(two_chunks.id, [%{name: name, type: "place"}], repo: Repo)
      end

      assert count_entities(one_chunk) == count_entities(two_chunks)
    end

    # The other half of the same constraint. Letting Postgres decide means
    # two spellings that share an Elixir key can land on two rows, so the
    # returned map has to reach BOTH of them. Keying it on the Elixir key
    # alone made the second upsert overwrite the first: every mention went
    # to the second row, the first was left orphaned, and searching for
    # the first spelling found a row with no chunks behind it.
    #
    # U+0130 is only the representative pair here because it diverges by
    # Unicode's own SpecialCasing rules rather than by glibc version, which
    # makes it the one pair that behaves the same on every Postgres build.
    # The fix keys raw names, so it covers the whole open-ended set.
    test "keeps every row reachable when two spellings share an Elixir key" do
      collection = create_collection()
      chunk = collection |> create_document() |> create_chunk()
      names = ["İstanbul", "i" <> <<0x307::utf8>> <> "stanbul"]

      # Precondition: one Elixir key, two Postgres keys.
      assert names |> Enum.map(&EntityName.normalize/1) |> Enum.uniq() |> length() == 1

      {:ok, id_map} =
        EctoStore.persist_entities(
          collection.id,
          Enum.map(names, &%{name: &1, type: "place"}),
          repo: Repo
        )

      assert count_entities(collection) == 2

      :ok =
        EctoStore.persist_mentions(
          Enum.map(names, &%{entity_name: &1, chunk_id: chunk.id}),
          id_map,
          repo: Repo
        )

      # No row is left without mentions...
      assert mention_counts(collection) == [1, 1]

      # ...and every spelling still finds its chunk.
      for name <- names do
        assert [%{chunk_id: found}] = EctoStore.search([name], [collection.id], repo: Repo)
        assert found == chunk.id
      end
    end

    test "resolves relationship endpoints to the row each raw name landed in" do
      collection = create_collection()
      decomposed = "i" <> <<0x307::utf8>> <> "stanbul"
      names = ["İstanbul", decomposed]

      {:ok, id_map} =
        EctoStore.persist_entities(
          collection.id,
          Enum.map(names, &%{name: &1, type: "place"}),
          repo: Repo
        )

      :ok =
        EctoStore.persist_relationships(
          [%{source: "İstanbul", target: decomposed, type: "spelled_as"}],
          id_map,
          repo: Repo
        )

      assert [rel] = Repo.all(Relationship)
      refute rel.source_id == rel.target_id
      assert Repo.get(Entity, rel.source_id).name == "İstanbul"
      assert Repo.get(Entity, rel.target_id).name == decomposed
    end

    test "still resolves names the call never persisted through the normalized key" do
      collection = create_collection()
      existing = create_entity(collection, "Alice", "person")
      chunk = collection |> create_document() |> create_chunk()

      # A map an earlier chunk (or a caller) built: normalized keys only.
      :ok =
        EctoStore.persist_mentions(
          [%{entity_name: "ALICE", chunk_id: chunk.id}],
          %{"alice" => existing.id},
          repo: Repo
        )

      assert Repo.aggregate(from(m in EntityMention, where: m.entity_id == ^existing.id), :count) ==
               1
    end

    test "inserts entity with metadata" do
      collection = create_collection()

      entities = [
        %{
          name: "Alice",
          type: "person",
          metadata: %{"age" => 30, "city" => "New York"}
        }
      ]

      {:ok, id_map} = EctoStore.persist_entities(collection.id, entities, repo: Repo)
      alice_id = id_map["alice"]

      alice = Repo.get(Entity, alice_id)
      assert alice.metadata == %{"age" => 30, "city" => "New York"}
    end
  end

  describe "persist_relationships/3" do
    test "inserts relationships between entities" do
      collection = create_collection()
      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")
      entity_id_map = %{"alice" => alice.id, "bob" => bob.id}

      relationships = [
        %{source: "Alice", target: "Bob", type: "knows"}
      ]

      assert :ok = EctoStore.persist_relationships(relationships, entity_id_map, repo: Repo)

      rel = Repo.get_by(Relationship, source_id: alice.id, target_id: bob.id)
      assert rel.type == "knows"
    end

    test "inserts relationships with metadata" do
      collection = create_collection()
      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")
      entity_id_map = %{"alice" => alice.id, "bob" => bob.id}

      relationships = [
        %{
          source: "Alice",
          target: "Bob",
          type: "knows",
          description: "Alice knows Bob",
          metadata: %{"since" => "2020"}
        }
      ]

      assert :ok = EctoStore.persist_relationships(relationships, entity_id_map, repo: Repo)

      rel = Repo.get_by(Relationship, source_id: alice.id, target_id: bob.id)
      assert rel.type == "knows"
      assert rel.description == "Alice knows Bob"
      assert rel.metadata == %{"since" => "2020"}
    end

    test "skips relationships with missing entities" do
      entity_id_map = %{"alice" => Ecto.UUID.generate()}

      relationships = [
        %{source: "Alice", target: "Unknown", type: "knows"}
      ]

      assert :ok = EctoStore.persist_relationships(relationships, entity_id_map, repo: Repo)
      assert Repo.aggregate(Relationship, :count) == 0
    end
  end

  describe "persist_mentions/3" do
    test "inserts entity mentions linking to chunks" do
      collection = create_collection()
      document = create_document(collection)
      chunk = create_chunk(document)
      alice = create_entity(collection, "Alice")
      entity_id_map = %{"alice" => alice.id}

      mentions = [
        %{entity_name: "Alice", chunk_id: chunk.id}
      ]

      assert :ok = EctoStore.persist_mentions(mentions, entity_id_map, repo: Repo)

      mention = Repo.get_by(EntityMention, entity_id: alice.id, chunk_id: chunk.id)
      assert mention
    end
  end

  describe "search/3" do
    test "finds chunks by entity names and scores by mention count" do
      collection = create_collection()
      document = create_document(collection)
      chunk1 = create_chunk(document, "Chunk with both")
      chunk2 = create_chunk(document, "Chunk with one")

      alice = create_entity(collection, "Alice")
      bob = create_entity(collection, "Bob")

      # chunk1 mentioned by both Alice and Bob (higher score)
      create_mention(alice, chunk1)
      create_mention(bob, chunk1)
      # chunk2 mentioned only by Alice
      create_mention(alice, chunk2)

      results = EctoStore.search(["Alice", "Bob"], [collection.id], repo: Repo)

      assert length(results) == 2
      # chunk1 should be first (higher score)
      [first, second] = results
      assert first.chunk_id == chunk1.id
      assert first.score > second.score
    end

    test "returns empty list when no entities match" do
      results = EctoStore.search(["Unknown"], nil, repo: Repo)
      assert results == []
    end

    test "matches stored name variants, not just the exact stored spelling" do
      collection = create_collection()
      chunk = collection |> create_document() |> create_chunk()

      # Write-side dedup collapses variants onto one row that keeps its
      # first-seen display name, so the read path has to normalize too or
      # legacy rows become unreachable from the names extractors now emit.
      warranty = create_entity(collection, "Two_Year_Limited_Warranty", "concept")
      create_mention(warranty, chunk)

      results = EctoStore.search(["two year limited warranty"], [collection.id], repo: Repo)

      assert [%{chunk_id: chunk_id}] = results
      assert chunk_id == chunk.id
    end

    # The upsert side is self-consistent whatever the stored name carries,
    # because both of its sides go through the same SQL. The read path
    # compares a stored name against one an extractor just emitted, so any
    # whitespace the normalization fails to fold makes the stored row
    # unreachable. btrim only strips U+0020, and Postgres' `\s` doesn't
    # match NBSP — the character every HTML/PDF-derived name arrives with.
    for {label, stored, queried} <- [
          {"trailing NBSP", "Delivery\u{a0}", "Delivery"},
          {"leading NBSP", "\u{a0}Delivery", "Delivery"},
          {"mid-string NBSP", "Acme\u{a0}Corp", "Acme Corp"},
          {"trailing thin space", "Delivery\u{2009}", "Delivery"},
          {"mid-string ideographic space", "Acme\u{3000}Corp", "Acme Corp"}
        ] do
      test "reaches an entity stored with a #{label} from its plain spelling" do
        collection = create_collection()
        chunk = collection |> create_document() |> create_chunk()

        entity = create_entity(collection, unquote(stored), "concept")
        create_mention(entity, chunk)

        results = EctoStore.search([unquote(queried)], [collection.id], repo: Repo)

        assert [%{chunk_id: chunk_id}] = results
        assert chunk_id == chunk.id
      end
    end

    test "empty collection_ids matches nothing instead of searching globally" do
      collection = create_collection()
      document = create_document(collection)
      chunk = create_chunk(document)
      alice = create_entity(collection, "Alice")
      create_mention(alice, chunk)

      # nil is unscoped, [] means the caller named collections that resolved
      # to nothing: leaking to a global search here is a cross-tenant bug
      assert EctoStore.search(["Alice"], nil, repo: Repo) != []
      assert EctoStore.search(["Alice"], [], repo: Repo) == []
    end
  end

  describe "search_by_embedding/3" do
    test "empty collection_ids matches nothing instead of searching globally" do
      collection = create_collection()
      entity = create_entity(collection, "Alice")

      entity
      |> Ecto.Changeset.change(embedding: Enum.map(1..384, fn _ -> 0.1 end))
      |> Repo.update!()

      query_embedding = Enum.map(1..384, fn _ -> 0.1 end)

      refute EctoStore.search_by_embedding(query_embedding, nil, repo: Repo, threshold: 0.1) == []
      assert EctoStore.search_by_embedding(query_embedding, [], repo: Repo, threshold: 0.1) == []
    end
  end

  describe "with_write_lock/3" do
    test "runs the function under the collection's advisory lock" do
      collection = create_collection("locked-collection")
      other = create_collection("other-collection")

      assert :ran == EctoStore.with_write_lock(collection.id, [repo: Repo], fn -> :ran end)

      # The sandbox keeps this test's transaction open, so the xact lock
      # is still held: an independent connection cannot take the same key.
      refute advisory_lock_free?(collection.id)
      assert advisory_lock_free?(other.id)
    end

    test "sweep_orphans/2 takes the same lock, so it can't interleave with a build" do
      collection = create_collection("swept-collection")

      :ok = EctoStore.sweep_orphans(collection.id, repo: Repo)

      refute advisory_lock_free?(collection.id)
    end

    test "build_and_persist/4 takes the same lock while persisting a chunk" do
      collection = create_collection("build-locked")
      chunk = collection |> create_document() |> create_chunk()
      extractor = fn _text, _opts -> {:ok, [%{name: "Locky", type: "concept"}]} end

      {:ok, _} =
        Arcana.Graph.build_and_persist([chunk], collection, Repo, entity_extractor: extractor)

      refute advisory_lock_free?(collection.id)
    end
  end

  describe "build_and_persist/4 reporting" do
    # entity_count is the number of entity rows the build touched, and the
    # Ecto store's id map holds more than one key per row (see
    # persist_entities/3), so counting keys would inflate it into the
    # documents and maintenance UIs.
    test "counts entity rows, not id-map keys" do
      collection = create_collection("counted")
      chunk = collection |> create_document() |> create_chunk()
      extractor = fn _text, _opts -> {:ok, [%{name: "Alice", type: "person"}]} end

      {:ok, result} =
        Arcana.Graph.build_and_persist([chunk], collection, Repo, entity_extractor: extractor)

      assert result.entity_count == 1
      assert result.entity_count == count_entities(collection)
    end
  end

  # Asks a connection outside the sandbox whether the graph write lock for
  # this collection is available. pg_try_advisory_xact_lock releases at the
  # end of its own (implicit) transaction, so this only observes.
  defp advisory_lock_free?(collection_id) do
    conn_opts =
      Arcana.TestRepo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])

    {:ok, conn} = Postgrex.start_link(conn_opts)

    %Postgrex.Result{rows: [[free]]} =
      Postgrex.query!(conn, "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))", [
        "arcana:graph:#{collection_id}"
      ])

    GenServer.stop(conn)
    free
  end

  describe "find_entities/2" do
    test "returns all entities in collection" do
      collection = create_collection("test-find")
      other_collection = create_collection("other")

      create_entity(collection, "Alice", "person")
      create_entity(collection, "Bob", "person")
      create_entity(other_collection, "Other", "person")

      entities = EctoStore.find_entities(collection.id, repo: Repo)

      assert length(entities) == 2
      names = Enum.map(entities, & &1.name)
      assert "Alice" in names
      assert "Bob" in names
    end
  end
end
