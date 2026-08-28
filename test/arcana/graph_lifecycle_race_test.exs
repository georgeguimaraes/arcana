defmodule Arcana.GraphLifecycleRaceTest do
  use Arcana.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox

  alias Arcana.{Chunk, Collection, Document}

  test "external delete retires the chunk before queued graph persistence can write" do
    collection = create_collection("delete-race")
    document = create_document(collection, :processing, "delete-race")
    chunk = create_chunk(document, "Alice knows Bob")
    chunk_id = chunk.id
    opts = lifecycle_opts(collection)
    collection_id = collection.id

    delete_task = async_with_repo(fn -> Arcana.delete(document.id, opts) end)
    {delete_ref, ^collection_id} = await_lock(delete_task.pid)

    persist_task = async_with_repo(fn -> persist_chunk(chunk, collection, opts) end)
    {persist_ref, ^collection_id} = await_lock(persist_task.pid)

    grant_lock(delete_task.pid, delete_ref)
    assert :ok = Task.await(delete_task)
    assert_receive {:graph_lock_released, _, ^delete_ref, _}

    grant_lock(persist_task.pid, persist_ref)

    assert {:ok, %{entity_count: 0, relationship_count: 0}} = Task.await(persist_task)
    assert_receive {:graph_lock_released, _, ^persist_ref, _}
    refute_received {:controlled_graph_store, {:persist_relationships, ^chunk_id, _}}
  end

  test "external replace retires predecessor chunks before queued persistence can write" do
    collection = create_collection("replace-race")
    predecessor = create_document(collection, :processing, "same-source")
    predecessor_chunk = create_chunk(predecessor, "Alice knows Bob")
    predecessor_chunk_id = predecessor_chunk.id
    opts = lifecycle_opts(collection, source_id: "same-source", replace: true)
    collection_id = collection.id

    replace_task =
      async_with_repo(fn ->
        Arcana.ingest("replacement", opts)
      end)

    {build_ref, ^collection_id} = await_lock(replace_task.pid)
    grant_lock(replace_task.pid, build_ref)
    assert_receive {:graph_lock_released, _, ^build_ref, _}

    {replace_ref, ^collection_id} = await_lock(replace_task.pid)

    persist_task =
      async_with_repo(fn -> persist_chunk(predecessor_chunk, collection, opts) end)

    {persist_ref, ^collection_id} = await_lock(persist_task.pid)

    grant_lock(replace_task.pid, replace_ref)
    assert {:ok, replacement} = Task.await(replace_task)
    assert replacement.source_id == "same-source"
    assert_receive {:graph_lock_released, _, ^replace_ref, _}

    grant_lock(persist_task.pid, persist_ref)

    assert {:ok, %{entity_count: 0, relationship_count: 0}} = Task.await(persist_task)
    assert_receive {:graph_lock_released, _, ^persist_ref, _}

    refute Repo.get(Document, predecessor.id)

    refute_received {:controlled_graph_store, {:persist_relationships, ^predecessor_chunk_id, _}}
  end

  defp lifecycle_opts(collection, extra \\ []) do
    Keyword.merge(
      [
        repo: Repo,
        graph: true,
        graph_store: {Arcana.ControlledGraphStore, coordinator: self(), notify: self()},
        entity_extractor: fn _text, _opts ->
          {:ok, [%{name: "Alice", type: "person"}, %{name: "Bob", type: "person"}]}
        end,
        relationship_extractor: fn _text, _entities, _opts ->
          {:ok, [%{source: "Alice", target: "Bob", type: "knows"}]}
        end,
        collection: collection.name
      ],
      extra
    )
  end

  defp persist_chunk(chunk, collection, opts) do
    Arcana.Graph.build_and_persist([chunk], collection, Repo, opts)
  end

  defp async_with_repo(fun) do
    task =
      Task.async(fn ->
        receive do
          :run -> fun.()
        end
      end)

    Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :run)
    task
  end

  defp await_lock(pid) do
    assert_receive {:graph_lock_waiting, ^pid, ref, collection_id}, 1_000
    {ref, collection_id}
  end

  defp grant_lock(pid, ref), do: send(pid, {:grant_graph_lock, ref})

  defp create_collection(prefix) do
    %Collection{}
    |> Collection.changeset(%{name: "#{prefix}-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp create_document(collection, status, source_id) do
    %Document{}
    |> Document.changeset(%{
      content: "predecessor",
      collection_id: collection.id,
      source_id: source_id,
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
