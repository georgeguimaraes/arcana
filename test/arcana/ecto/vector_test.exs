defmodule OpaqueVector do
  @moduledoc false
  defstruct [:blob]
end

defmodule Arcana.Ecto.VectorTest do
  use Arcana.DataCase, async: true

  alias Arcana.Chunk
  alias Arcana.Ecto.Vector

  describe "equal?/2" do
    test "byte-identical values are equal across representations" do
      list = [1.0, 2.5, -3.25]
      pgv = Pgvector.new(list)

      assert Vector.equal?(list, list)
      assert Vector.equal?(pgv, pgv)
      assert Vector.equal?(list, pgv)
      assert Vector.equal?(pgv, list)
    end

    test "different values are not equal" do
      refute Vector.equal?([1.0, 2.0], [1.0, 2.1])
      refute Vector.equal?(Pgvector.new([1.0]), Pgvector.new([2.0]))
      refute Vector.equal?([1.0], nil)
    end

    test "nil equals nil" do
      assert Vector.equal?(nil, nil)
    end

    test "uncastable values fall back to structural comparison without raising" do
      refute Vector.equal?("not a vector", [1.0])
      assert Vector.equal?("same", "same")
    end

    test "an enumerable struct from a custom decoder compares by value" do
      # A custom Postgrex types module can decode vectors into its own
      # struct; as long as it enumerates to the same numbers it must
      # compare equal to the list/Pgvector representations (issue #98).
      # A range stands in for that struct here: protocols are
      # consolidated in test, so an Enumerable impl defined in this file
      # would be invisible at runtime.
      enumerable_struct = 1..3

      assert Vector.equal?(enumerable_struct, [1.0, 2.0, 3.0])
      assert Vector.equal?([1.0, 2.0, 3.0], enumerable_struct)
      assert Vector.equal?(enumerable_struct, Pgvector.new([1.0, 2.0, 3.0]))
      refute Vector.equal?(enumerable_struct, [1.0, 2.0, 3.5])
    end

    test "an enumerable that raises falls back instead of crashing" do
      # Streams are enumerable structs, so normalize/1 tries to walk them;
      # a raising one must degrade to structural comparison, not blow up
      # the caller's changeset
      raising = Stream.map([1], fn _ -> raise "boom" end)

      refute Vector.equal?(raising, [1.0])
      refute Vector.equal?([1.0], raising)
    end

    test "an opaque struct falls back to structural comparison" do
      opaque = %OpaqueVector{blob: "unknown"}

      assert Vector.equal?(opaque, opaque)
      refute Vector.equal?(opaque, [1.0])
    end
  end

  describe "changeset dirty tracking" do
    test "casting an equal value produces no change" do
      # The discriminating case: cast/3 encodes the incoming list, and
      # without equal?/2 the loaded representation and the cast one
      # compare unequal, marking the embedding changed on every re-store.
      chunk = %Chunk{text: "x", embedding: [1.0, 2.0]}

      changeset = Ecto.Changeset.cast(chunk, %{"embedding" => [1.0, 2.0]}, [:embedding])

      assert changeset.changes == %{}
    end

    test "a genuinely different embedding is still detected" do
      chunk = %Chunk{text: "x", embedding: [1.0, 2.0]}

      changeset = Ecto.Changeset.cast(chunk, %{"embedding" => [1.0, 2.5]}, [:embedding])

      assert Map.has_key?(changeset.changes, :embedding)
    end

    test "re-storing a byte-identical embedding leaves the row untouched" do
      {:ok, doc} = Arcana.ingest("Vector equality regression", repo: Repo)

      chunk = Repo.one!(from(c in Chunk, where: c.document_id == ^doc.id, limit: 1))
      same_embedding = Pgvector.to_list(chunk.embedding)

      changeset = Chunk.changeset(chunk, %{embedding: same_embedding})
      {:ok, updated} = Repo.update(changeset)

      assert updated.updated_at == chunk.updated_at
    end

    test "a changed embedding round-trips through the database" do
      {:ok, doc} = Arcana.ingest("Vector inequality regression", repo: Repo)

      chunk = Repo.one!(from(c in Chunk, where: c.document_id == ^doc.id, limit: 1))
      [first | rest] = Pgvector.to_list(chunk.embedding)
      changed = [first + 1.0 | rest]

      {:ok, _} = chunk |> Chunk.changeset(%{embedding: changed}) |> Repo.update()

      # The column is float4, so compare against the f32-normalized value
      # rather than the f64 arithmetic result
      expected = changed |> Pgvector.new() |> Pgvector.to_list()
      reloaded = Repo.reload!(chunk).embedding |> Pgvector.to_list()

      assert reloaded == expected
      refute reloaded == Pgvector.to_list(chunk.embedding)
    end
  end
end
