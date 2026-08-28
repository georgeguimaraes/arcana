defmodule Arcana.ControlledGraphStore do
  @moduledoc false

  alias Arcana.Graph.EntityName

  def with_write_lock(collection_id, opts, fun) do
    coordinator = Keyword.fetch!(opts, :coordinator)
    ref = make_ref()
    send(coordinator, {:graph_lock_waiting, self(), ref, collection_id})

    receive do
      {:grant_graph_lock, ^ref} ->
        try do
          fun.()
        after
          send(coordinator, {:graph_lock_released, self(), ref, collection_id})
        end
    end
  end

  def persist_entities(collection_id, entities, opts) do
    notify(opts, {:persist_entities, collection_id, Enum.map(entities, & &1.name)})
    {:ok, Map.new(entities, fn entity -> {EntityName.normalize(entity.name), entity.name} end)}
  end

  def persist_mentions(mentions, _entity_id_map, opts) do
    notify(opts, {:persist_mentions, Enum.map(mentions, & &1.chunk_id)})
    :ok
  end

  def persist_relationships(chunk_id, relationships, _entity_id_map, opts) do
    notify(opts, {:persist_relationships, chunk_id, length(relationships)})
    :ok
  end

  def delete_by_chunks(chunk_ids, opts) do
    notify(opts, {:delete_by_chunks, chunk_ids})
    :ok
  end

  defp notify(opts, message) do
    if notify = Keyword.get(opts, :notify), do: send(notify, {:controlled_graph_store, message})
  end
end
