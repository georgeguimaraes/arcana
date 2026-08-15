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
  end

  describe "changeset dirty tracking" do
    test "re-storing a byte-identical embedding is a no-op change" do
      {:ok, doc} = Arcana.ingest("Vector equality regression", repo: Repo)

      chunk = Repo.one!(from(c in Chunk, where: c.document_id == ^doc.id, limit: 1))
      same_embedding = Pgvector.to_list(chunk.embedding)

      changeset = Chunk.changeset(chunk, %{embedding: same_embedding})

      # Before Arcana.Ecto.Vector, comparing the loaded %Pgvector{}
      # against a cast list dirtied the changeset on every re-store
      assert changeset.changes == %{}

      {:ok, updated} = Repo.update(changeset)
      assert updated.updated_at == chunk.updated_at
    end

    test "a genuinely different embedding is still detected" do
      {:ok, doc} = Arcana.ingest("Vector inequality regression", repo: Repo)

      chunk = Repo.one!(from(c in Chunk, where: c.document_id == ^doc.id, limit: 1))
      [first | rest] = Pgvector.to_list(chunk.embedding)

      changeset = Chunk.changeset(chunk, %{embedding: [first + 1.0 | rest]})

      assert Map.has_key?(changeset.changes, :embedding)
    end
  end
end
