defmodule Arcana.MaintenanceCommunitiesTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection
  alias Arcana.Graph.{Community, CommunitySummarizer, Entity, Relationship}
  alias Arcana.Maintenance

  defmodule TwoLevelDetector do
    @moduledoc false
    @behaviour Arcana.Graph.CommunityDetector

    @impl true
    def detect(entities, _relationships, _opts) do
      ids = Enum.map(entities, & &1.id)
      {:ok, [%{level: 0, entity_ids: ids}, %{level: 1, entity_ids: ids}]}
    end
  end

  defmodule StubDetector do
    @moduledoc false
    @behaviour Arcana.Graph.CommunityDetector

    @impl true
    def detect(entities, _relationships, opts) do
      send(self(), {:detector_opts, opts})
      {:ok, [%{level: 0, entity_ids: Enum.map(entities, & &1.id)}]}
    end
  end

  setup do
    name = "communities-#{System.unique_integer([:positive])}"
    {:ok, collection} = Collection.get_or_create(name, Repo)

    # Two tight clusters joined by a weak bridge.
    entities =
      for entity_name <- ~w(a b c d e f) do
        %Entity{}
        |> Entity.changeset(%{
          name: "#{entity_name}-#{name}",
          type: "thing",
          collection_id: collection.id
        })
        |> Repo.insert!()
      end

    [a, b, c, d, e, f] = entities

    for {source, target, strength} <- [
          {a, b, 10},
          {b, c, 10},
          {a, c, 10},
          {d, e, 10},
          {e, f, 10},
          {d, f, 10},
          {c, d, 1}
        ] do
      %Relationship{}
      |> Relationship.changeset(%{
        type: "RELATED",
        source_id: source.id,
        target_id: target.id,
        strength: strength
      })
      |> Repo.insert!()
    end

    %{collection: collection, entities: entities}
  end

  defp summarized_as_a_real_run_would(community, summary) do
    entity_ids = community.entity_ids || []

    entities =
      Repo.all(
        from(e in Entity,
          where: e.id in ^entity_ids,
          select: %{id: e.id, name: e.name, type: e.type, description: e.description}
        )
      )

    relationships =
      Repo.all(
        from(r in Relationship,
          where: r.source_id in ^entity_ids and r.target_id in ^entity_ids,
          select: %{
            source_id: r.source_id,
            target_id: r.target_id,
            type: r.type,
            description: r.description
          }
        )
      )

    community
    |> Community.changeset(%{
      summary: summary,
      dirty: false,
      summary_fingerprint: CommunitySummarizer.content_fingerprint(entities, relationships)
    })
    |> Repo.update!()
  end

  defp communities(collection) do
    Repo.all(from(c in Community, where: c.collection_id == ^collection.id, order_by: c.level))
  end

  defp membership(collection) do
    collection
    |> communities()
    |> Enum.map(&Enum.sort(&1.entity_ids))
    |> Enum.sort()
  end

  describe "detect_communities/2 configuration" do
    test "reads seed, objective and iterations from the graph config", %{collection: collection} do
      put_arcana_env(:graph,
        community_detector: {StubDetector, []},
        seed: 42,
        objective: :modularity,
        iterations: 7
      )

      assert {:ok, %{communities: 1}} =
               Maintenance.detect_communities(Repo, collection: collection.name)

      assert_received {:detector_opts, opts}
      assert opts[:seed] == 42
      assert opts[:objective] == :modularity
      assert opts[:iterations] == 7
    end

    test "per-call options win over the graph config", %{collection: collection} do
      put_arcana_env(:graph,
        community_detector: {StubDetector, []},
        seed: 42,
        objective: :modularity,
        min_size: 3
      )

      assert {:ok, _} =
               Maintenance.detect_communities(Repo,
                 collection: collection.name,
                 seed: 99,
                 objective: :cpm,
                 min_size: 1
               )

      assert_received {:detector_opts, opts}
      assert opts[:seed] == 99
      assert opts[:objective] == :cpm
      assert opts[:min_size] == 1
    end

    test "detector options win over the generic graph knobs", %{collection: collection} do
      put_arcana_env(:graph,
        community_detector: {StubDetector, seed: 7},
        seed: 42
      )

      assert {:ok, _} = Maintenance.detect_communities(Repo, collection: collection.name)

      assert_received {:detector_opts, opts}
      assert opts[:seed] == 7
    end

    test "community_detector config replaces the built-in Leiden detector", %{
      collection: collection,
      entities: entities
    } do
      put_arcana_env(:graph, community_detector: {StubDetector, []})

      assert {:ok, %{communities: 1}} =
               Maintenance.detect_communities(Repo, collection: collection.name)

      # The stub lumps every entity into one community; Leiden would not.
      assert membership(collection) == [entities |> Enum.map(& &1.id) |> Enum.sort()]
    end

    test "summary reuse keys on level, so two levels sharing a membership don't swap", %{
      collection: collection
    } do
      # Keyed on membership alone, these two collapse to one key and whichever
      # row Postgres returned last wins - nondeterministically.
      put_arcana_env(:graph, community_detector: {TwoLevelDetector, []})

      assert {:ok, _} = Maintenance.detect_communities(Repo, collection: collection.name)

      for community <- Repo.all(Community) do
        community
        |> Community.changeset(%{summary: "level #{community.level} summary", dirty: false})
        |> Repo.update!()
      end

      assert {:ok, _} = Maintenance.detect_communities(Repo, collection: collection.name)

      after_rerun =
        Community
        |> Repo.all()
        |> Map.new(&{&1.level, &1.summary})

      assert after_rerun[0] == "level 0 summary"
      assert after_rerun[1] == "level 1 summary"
    end

    test "configured_detector/0 reports the detector that will actually run" do
      # The detect_communities mix task guards on this rather than assuming
      # Leiden, so a custom detector doesn't have to drag in leidenfold.
      put_arcana_env(:graph, community_detector: {StubDetector, []})
      assert {StubDetector, _opts} = Maintenance.configured_detector()
    end

    test "configured_detector/0 falls back to the built-in Leiden detector" do
      assert {Arcana.Graph.CommunityDetector.Leiden, _opts} = Maintenance.configured_detector()
    end

    test "a seed from config makes membership reproducible across runs", %{
      collection: collection
    } do
      put_arcana_env(:graph, seed: 42, objective: :cpm, iterations: 2, community_levels: 1)

      assert {:ok, _} = Maintenance.detect_communities(Repo, collection: collection.name)
      first_run = membership(collection)

      assert {:ok, _} = Maintenance.detect_communities(Repo, collection: collection.name)
      second_run = membership(collection)

      assert first_run != []
      assert first_run == second_run
    end
  end

  describe "detect_communities/2 summary reuse" do
    test "keeps summaries for memberships that didn't change", %{collection: collection} do
      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      before = communities(collection)
      assert length(before) > 1

      for community <- before do
        summarized_as_a_real_run_would(community, "summary of #{length(community.entity_ids)}")
      end

      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      after_rerun = communities(collection)
      assert membership(collection) == Enum.sort(Enum.map(before, &Enum.sort(&1.entity_ids)))

      for community <- after_rerun do
        assert community.summary == "summary of #{length(community.entity_ids)}"
        refute community.dirty
      end
    end

    test "a community still awaiting a refresh stays dirty", %{collection: collection} do
      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      [stale | rest] = communities(collection)

      stale
      |> Community.changeset(%{summary: "stale summary", dirty: true, change_count: 3})
      |> Repo.update!()

      for community <- rest do
        community |> Community.changeset(%{summary: "clean", dirty: false}) |> Repo.update!()
      end

      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      stale_ids = Enum.sort(stale.entity_ids)
      reused = Enum.find(communities(collection), &(Enum.sort(&1.entity_ids) == stale_ids))

      assert reused.summary == "stale summary"
      assert reused.dirty
      assert reused.change_count == 3
    end

    test "a relationship added between existing members invalidates the summary", %{
      collection: collection,
      entities: entities
    } do
      # The case membership can't see: ingesting another document adds
      # relationships between entities that are already in the community, so
      # the entity set is byte-identical while what the summary should say
      # has changed. Without a recorded fingerprint this stayed clean forever.
      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      for community <- communities(collection) do
        summarized_as_a_real_run_would(community, "before the new edge")
      end

      [a, b | _] = entities

      %Relationship{}
      |> Relationship.changeset(%{
        source_id: a.id,
        target_id: b.id,
        type: "newly-discovered",
        strength: 1
      })
      |> Repo.insert!()

      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      touched =
        communities(collection)
        |> Enum.filter(&(a.id in &1.entity_ids and b.id in &1.entity_ids))

      assert touched != [], "expected a community holding both endpoints"

      for community <- touched do
        assert community.summary == "before the new edge", "the text should stay readable"
        assert community.dirty, "a changed community must be queued for a refresh"
      end
    end

    test "new memberships come back dirty with no summary", %{collection: collection} do
      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      for community <- communities(collection) do
        summarized_as_a_real_run_would(community, "old")
      end

      %Entity{}
      |> Entity.changeset(%{
        name: "loner-#{collection.name}",
        type: "thing",
        collection_id: collection.id
      })
      |> Repo.insert!()

      assert {:ok, _} =
               Maintenance.detect_communities(Repo, collection: collection.name, seed: 42)

      communities = communities(collection)
      {fresh, reused} = Enum.split_with(communities, &is_nil(&1.summary))

      assert length(fresh) == 1
      assert Enum.all?(fresh, & &1.dirty)
      assert reused != []
      assert Enum.all?(reused, &(&1.summary == "old" and not &1.dirty))
    end
  end

  describe "summarize_communities/2 levels" do
    setup %{collection: collection, entities: entities} do
      ids = Enum.map(entities, & &1.id)

      for level <- 0..2 do
        %Community{}
        |> Community.changeset(%{
          level: level,
          entity_ids: ids,
          collection_id: collection.id,
          dirty: true
        })
        |> Repo.insert!()
      end

      %{llm: [llm: fn _prompt, _context, _opts -> {:ok, "a summary"} end]}
    end

    test "only summarizes the levels a query can read", %{collection: collection, llm: llm} do
      assert {:ok, %{communities: 1, summaries: 1}} =
               Maintenance.summarize_communities(Repo, [collection: collection.name] ++ llm)

      by_level = Map.new(communities(collection), &{&1.level, &1})

      assert by_level[0].summary == "a summary"
      refute by_level[0].dirty
      assert is_nil(by_level[1].summary)
      assert is_nil(by_level[2].summary)
    end

    test "follows community_summary_level when it names several levels", %{
      collection: collection,
      llm: llm
    } do
      put_arcana_env(:graph, community_summary_level: 0..1)

      assert {:ok, %{communities: 2, summaries: 2}} =
               Maintenance.summarize_communities(Repo, [collection: collection.name] ++ llm)

      by_level = Map.new(communities(collection), &{&1.level, &1})

      assert by_level[0].summary == "a summary"
      assert by_level[1].summary == "a summary"
      assert is_nil(by_level[2].summary)
    end

    test "levels: :all opts every level back in", %{collection: collection, llm: llm} do
      assert {:ok, %{communities: 3, summaries: 3}} =
               Maintenance.summarize_communities(
                 Repo,
                 [collection: collection.name, levels: :all] ++ llm
               )

      assert Enum.all?(communities(collection), &(&1.summary == "a summary"))
    end

    test "force re-summarizes clean communities in the selected levels", %{
      collection: collection,
      llm: llm
    } do
      for community <- communities(collection) do
        community |> Community.changeset(%{summary: "old", dirty: false}) |> Repo.update!()
      end

      assert {:ok, %{summaries: 3}} =
               Maintenance.summarize_communities(
                 Repo,
                 [collection: collection.name, levels: :all, force: true] ++ llm
               )

      assert Enum.all?(communities(collection), &(&1.summary == "a summary"))
    end
  end

  describe "detection_opts/1" do
    test "defaults the hierarchy ceiling to a single level" do
      # The documented default in Graph, Leiden and the detect docstring.
      assert Arcana.Graph.config().community_levels == 1
      assert Maintenance.detection_opts()[:max_level] == 1
    end

    test "layers defaults, graph config and per-call options" do
      put_arcana_env(:graph, seed: 42, objective: :modularity, community_levels: 3)

      opts = Maintenance.detection_opts(seed: 99)

      assert opts[:seed] == 99
      assert opts[:objective] == :modularity
      assert opts[:max_level] == 3
      assert opts[:iterations] == 2
    end
  end
end
