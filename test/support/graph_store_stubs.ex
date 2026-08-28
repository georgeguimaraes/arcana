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

  def persist_relationships(chunk_id, relationships, _entity_id_map, opts) do
    notify(opts, {:persist_relationships, chunk_id, length(relationships)})
    :ok
  end

  def persist_mentions(mentions, _entity_id_map, opts) do
    notify(opts, {:persist_mentions, length(mentions)})
    :ok
  end

  def delete_by_chunks(chunk_ids, opts) do
    notify(opts, {:delete_by_chunks, chunk_ids})
    :ok
  end

  def sweep_orphans(collection_id, opts) do
    notify(opts, {:sweep_orphans, collection_id})
    :ok
  end

  def with_write_lock(_collection_id, _opts, fun), do: fun.()

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

  def persist_relationships(_chunk_id, _relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok
  def delete_by_chunks(_chunk_ids, _opts), do: :ok

  def sweep_orphans(_collection_id, _opts), do: {:error, :sweep_boom}
  def with_write_lock(_collection_id, _opts, fun), do: fun.()
end

defmodule Arcana.FailingDeleteGraphStore do
  @moduledoc false

  alias Arcana.Graph.EntityName

  def persist_entities(_collection_id, entities, _opts) do
    {:ok, Map.new(entities, fn e -> {EntityName.normalize(e.name), e.name} end)}
  end

  def persist_relationships(_chunk_id, _relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok

  def delete_by_chunks(_chunk_ids, opts) do
    case Keyword.get(opts, :delete_failure, :return) do
      :ok -> :ok
      :return -> {:error, :delete_boom}
      :raise -> raise "delete_boom"
      :exit -> exit(:delete_boom)
    end
  end

  def sweep_orphans(_collection_id, _opts), do: :ok
  def with_write_lock(_collection_id, _opts, fun), do: fun.()
end

defmodule Arcana.RaisingDeleteGraphStore do
  @moduledoc false

  def delete_by_chunks(_chunk_ids, opts) do
    case Keyword.get(opts, :cleanup_failure, :stale) do
      :stale -> raise %Ecto.StaleEntryError{message: "external graph cleanup failed"}
      :exit -> exit(:external_cleanup_exit)
      :throw -> throw(:external_cleanup_throw)
    end
  end

  def sweep_orphans(_collection_id, _opts), do: :ok
  def with_write_lock(_collection_id, _opts, fun), do: fun.()
end

defmodule Arcana.LegacyGraphStore do
  @moduledoc false
  # A third-party store written against the graph store behaviour as it
  # stood before sweep_orphans/2 existed: everything but that callback.

  alias Arcana.Graph.EntityName

  def persist_entities(_collection_id, entities, _opts) do
    {:ok, Map.new(entities, fn e -> {EntityName.normalize(e.name), e.name} end)}
  end

  def persist_relationships(_chunk_id, _relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok
  def delete_by_chunks(_chunk_ids, _opts), do: :ok
  def with_write_lock(_collection_id, _opts, fun), do: fun.()
end

defmodule Arcana.RaisingGraphStore do
  @moduledoc false
  # Graph store that blows up mid-build, for the partial-document path.

  def persist_entities(_collection_id, _entities, _opts), do: raise("graph store exploded")
  def persist_relationships(_chunk_id, _relationships, _entity_id_map, _opts), do: :ok
  def persist_mentions(_mentions, _entity_id_map, _opts), do: :ok
  def sweep_orphans(_collection_id, _opts), do: :ok
  def with_write_lock(_collection_id, _opts, fun), do: fun.()
end
