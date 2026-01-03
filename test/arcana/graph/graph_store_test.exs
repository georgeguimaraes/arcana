defmodule Arcana.Graph.GraphStoreTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.GraphStore

  describe "behaviour" do
    test "defines persist_entities callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:persist_entities, 3} in callbacks
    end

    test "defines persist_relationships callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:persist_relationships, 3} in callbacks
    end

    test "defines persist_mentions callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:persist_mentions, 3} in callbacks
    end

    test "defines search callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:search, 3} in callbacks
    end

    test "defines find_entities callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:find_entities, 2} in callbacks
    end

    test "defines find_related_entities callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:find_related_entities, 3} in callbacks
    end

    test "defines persist_communities callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:persist_communities, 3} in callbacks
    end

    test "defines get_community_summaries callback" do
      callbacks = GraphStore.behaviour_info(:callbacks)
      assert {:get_community_summaries, 2} in callbacks
    end
  end

  describe "backend/0" do
    test "returns default :ecto backend" do
      assert GraphStore.backend() == :ecto
    end
  end
end
