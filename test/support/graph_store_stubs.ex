defmodule Arcana.SpyGraphStore do
  @moduledoc false
  # Records which graph-store callbacks a code path reaches, so tests can
  # prove build and sweep land on the same opts-provided backend.
  # Configure with `graph_store: {Arcana.SpyGraphStore, notify: self()}`.

  alias Arcana.Graph.EntityName

  def persist_entities(collection_id, entities, opts) do
    notify(opts, {:persist_entities, collection_id, Enum.map(entities, & &1.name)})
    {:ok, Map.new(entities, fn e -> {EntityName.normalize(e.name), e.name} end)}
  end

  def persist_relationships(relationships, _entity_id_map, opts) do
    notify(opts, {:persist_relationships, length(relationships)})
    :ok
  end

  def persist_mentions(mentions, _entity_id_map, opts) do
    notify(opts, {:persist_mentions, length(mentions)})
    :ok
  end

  def sweep_orphans(collection_id, opts) do
    notify(opts, {:sweep_orphans, collection_id})
    :ok
  end

  defp notify(opts, message) do
    case Keyword.get(opts, :notify) do
      nil -> :ok
      pid -> send(pid, {:spy_graph_store, message})
    end
  end
end

defmodule Arcana.FailingSweepGraphStore do
  @moduledoc false
  # Graph store whose sweep always fails, for the error-propagation paths.

  alias Arcana.Graph.EntityName

  def persist_entities(_collection_id, entities, _opts) do
    {:ok, Map.new(entities, fn e -> {EntityName.normalize(e.name), e.name} end)}
  end

  def persist_relationships(_relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok

  def sweep_orphans(_collection_id, _opts), do: {:error, :sweep_boom}
end

defmodule Arcana.LegacyGraphStore do
  @moduledoc false
  # A third-party store written against the graph store behaviour as it
  # stood before sweep_orphans/2 existed: everything but that callback.

  alias Arcana.Graph.EntityName

  def persist_entities(_collection_id, entities, _opts) do
    {:ok, Map.new(entities, fn e -> {EntityName.normalize(e.name), e.name} end)}
  end

  def persist_relationships(_relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok
end

defmodule Arcana.RaisingGraphStore do
  @moduledoc false
  # Graph store that blows up mid-build, for the partial-document path.

  def persist_entities(_collection_id, _entities, _opts), do: raise("graph store exploded")
  def persist_relationships(_relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok
  def sweep_orphans(_collection_id, _opts), do: :ok
end
