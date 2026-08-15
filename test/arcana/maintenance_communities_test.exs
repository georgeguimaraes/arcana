defmodule Arcana.MaintenanceCommunitiesTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection
  alias Arcana.Graph.{Community, Entity, Relationship}
  alias Arcana.Maintenance

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

  defp membership(collection) do
    Repo.all(from(c in Community, where: c.collection_id == ^collection.id))
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

  describe "detection_opts/1" do
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
