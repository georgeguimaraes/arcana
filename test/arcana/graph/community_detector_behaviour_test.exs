defmodule MockCommunityDetector do
  @behaviour Arcana.Graph.CommunityDetector

  @impl true
  def detect(entities, _relationships, opts) do
    # Simple mock: group all entities into one community
    group_size = Keyword.get(opts, :group_size, length(entities))

    communities =
      entities
      |> Enum.map(& &1.id)
      |> Enum.chunk_every(group_size)
      |> Enum.with_index()
      |> Enum.map(fn {ids, level} ->
        %{level: level, entity_ids: ids}
      end)

    {:ok, communities}
  end
end

defmodule MockCommunityDetectorWithError do
  @behaviour Arcana.Graph.CommunityDetector

  @impl true
  def detect(_entities, _relationships, _opts) do
    {:error, :detection_failed}
  end
end

defmodule Arcana.Graph.CommunityDetectorBehaviourTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.CommunityDetector

  @entities [
    %{id: "1", name: "A"},
    %{id: "2", name: "B"},
    %{id: "3", name: "C"},
    %{id: "4", name: "D"}
  ]

  @relationships [
    %{source_id: "1", target_id: "2", strength: 5}
  ]

  describe "detect/3 with module detector" do
    test "invokes module's detect callback" do
      detector = {MockCommunityDetector, []}

      {:ok, communities} = CommunityDetector.detect(detector, @entities, @relationships)

      assert is_list(communities)
      assert length(communities) == 1
      assert hd(communities).entity_ids == ["1", "2", "3", "4"]
    end

    test "passes options to module" do
      detector = {MockCommunityDetector, group_size: 2}

      {:ok, communities} = CommunityDetector.detect(detector, @entities, @relationships)

      # Should create 2 communities of 2 entities each
      assert length(communities) == 2
    end

    test "propagates errors from module" do
      detector = {MockCommunityDetectorWithError, []}

      assert {:error, :detection_failed} =
               CommunityDetector.detect(detector, @entities, @relationships)
    end
  end

  describe "detect/3 with function detector" do
    test "invokes inline function" do
      detector = fn entities, _relationships, _opts ->
        ids = Enum.map(entities, & &1.id)
        {:ok, [%{level: 0, entity_ids: ids}]}
      end

      {:ok, communities} = CommunityDetector.detect(detector, @entities, @relationships)

      assert [%{level: 0, entity_ids: ["1", "2", "3", "4"]}] = communities
    end

    test "propagates errors from inline function" do
      detector = fn _entities, _relationships, _opts ->
        {:error, :custom_error}
      end

      assert {:error, :custom_error} =
               CommunityDetector.detect(detector, @entities, @relationships)
    end
  end

  describe "detect/3 with nil detector" do
    test "returns empty communities when detector is nil" do
      {:ok, communities} = CommunityDetector.detect(nil, @entities, @relationships)

      assert communities == []
    end
  end
end
