defmodule Arcana.VectorStoreTest do
  use ExUnit.Case, async: true

  alias Arcana.VectorStore
  alias Arcana.VectorStore.Memory

  describe "per-call :vector_store option" do
    setup do
      {:ok, pid} = Memory.start_link(name: nil)
      %{pid: pid}
    end

    @tag :memory
    test "search uses {:memory, pid: pid} to override config", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)

      # Store directly via Memory
      :ok = Memory.store(pid, "test", "id-1", embedding, %{text: "hello"})

      # Search via dispatch with explicit vector_store option
      results =
        VectorStore.search("test", embedding,
          vector_store: {:memory, pid: pid},
          limit: 10
        )

      assert length(results) == 1
      assert hd(results).id == "id-1"
    end

    @tag :memory
    test "store uses {:memory, pid: pid} to override config", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)

      # Store via dispatch with explicit vector_store option
      :ok =
        VectorStore.store("test", "id-1", embedding, %{text: "hello"},
          vector_store: {:memory, pid: pid}
        )

      # Verify via direct Memory call
      results = Memory.search(pid, "test", embedding, limit: 10)
      assert length(results) == 1
    end

    @tag :memory
    test "delete uses {:memory, pid: pid} to override config", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      :ok = Memory.store(pid, "test", "id-1", embedding, %{text: "hello"})

      # Delete via dispatch
      :ok = VectorStore.delete("test", "id-1", vector_store: {:memory, pid: pid})

      # Verify deleted
      results = Memory.search(pid, "test", embedding, limit: 10)
      assert results == []
    end

    @tag :memory
    test "clear uses {:memory, pid: pid} to override config", %{pid: pid} do
      embedding = List.duplicate(0.5, 384)
      :ok = Memory.store(pid, "test", "id-1", embedding, %{text: "hello"})
      :ok = Memory.store(pid, "test", "id-2", embedding, %{text: "world"})

      # Clear via dispatch
      :ok = VectorStore.clear("test", vector_store: {:memory, pid: pid})

      # Verify cleared
      results = Memory.search(pid, "test", embedding, limit: 10)
      assert results == []
    end

    test "accepts custom module as :vector_store" do
      defmodule MockVectorStore do
        @behaviour Arcana.VectorStore

        def store(_collection, _id, _embedding, _metadata, opts) do
          send(opts[:test_pid], {:store_called, opts})
          :ok
        end

        def search(_collection, _embedding, opts) do
          send(opts[:test_pid], {:search_called, opts})
          []
        end

        def delete(_collection, _id, opts) do
          send(opts[:test_pid], {:delete_called, opts})
          :ok
        end

        def clear(_collection, opts) do
          send(opts[:test_pid], {:clear_called, opts})
          :ok
        end
      end

      embedding = List.duplicate(0.5, 384)

      VectorStore.search("test", embedding, vector_store: {MockVectorStore, test_pid: self()})

      assert_receive {:search_called, opts}
      assert opts[:test_pid] == self()

      VectorStore.store("test", "id", embedding, %{},
        vector_store: {MockVectorStore, test_pid: self()}
      )

      assert_receive {:store_called, _opts}

      VectorStore.delete("test", "id", vector_store: {MockVectorStore, test_pid: self()})

      assert_receive {:delete_called, _opts}

      VectorStore.clear("test",
        vector_store: {MockVectorStore, test_pid: self()}
      )

      assert_receive {:clear_called, _opts}
    end
  end
end
