defmodule Arcana.DeleteContractTest do
  @moduledoc """
  `Arcana.delete/2` returning what its docs promise.

  It used to call `repo.delete!/1`, so a foreign key violation or a
  concurrent delete escaped as an exception from a function documenting
  `:ok | {:error, :not_found} | {:error, {:sweep_failed, _}}`. The damage was
  not the exception itself but the sequencing around it: callers remove an
  external artifact and then call this, and a three-clause `case` written
  from the docs gave them no reason to expect control to leave abruptly.
  """
  use Arcana.DataCase, async: true

  alias Ecto.Adapters.SQL

  defp ingest_doc(text \\ "Elixir runs on the BEAM.") do
    {:ok, doc} = Arcana.ingest(text, repo: Repo)
    doc
  end

  describe "the documented happy paths still hold" do
    test "deleting a document returns :ok and removes it" do
      doc = ingest_doc()

      assert :ok = Arcana.delete(doc.id, repo: Repo)
      refute Repo.get(Arcana.Document, doc.id)
    end

    test "an unknown id is :not_found" do
      assert {:error, :not_found} = Arcana.delete(Ecto.UUID.generate(), repo: Repo)
    end
  end

  describe "database failures come back as tuples" do
    test "a foreign key violation is an error tuple, not an exception" do
      doc = ingest_doc()

      # A host table referencing the document with no cascade: deleting the
      # document is a constraint violation, which repo.delete!/1 raised.
      SQL.query!(
        Repo,
        "CREATE TABLE host_refs (id serial primary key, " <>
          "document_id uuid REFERENCES arcana_documents(id))",
        []
      )

      SQL.query!(Repo, "INSERT INTO host_refs (document_id) VALUES ($1)", [
        Ecto.UUID.dump!(doc.id)
      ])

      assert {:error, reason} = Arcana.delete(doc.id, repo: Repo)

      refute reason == :not_found,
             "a constraint violation is not a missing document"

      assert Repo.get(Arcana.Document, doc.id),
             "the document must survive a failed delete"
    end

    test "a document deleted out from under us reads as :not_found" do
      # This lands on the repo.get/2 branch, not the Ecto.StaleEntryError
      # rescue: the row is already gone by the time delete/2 looks for it.
      # Forcing the actual race - present at the lookup, gone at the delete -
      # needs an interleave inside delete/2 that the sandbox cannot arrange,
      # so the rescue itself is defensive and uncovered. It reports the same
      # :not_found either way, which is the contract being pinned here.
      doc = ingest_doc()

      SQL.query!(Repo, "DELETE FROM arcana_chunks WHERE document_id = $1", [
        Ecto.UUID.dump!(doc.id)
      ])

      SQL.query!(Repo, "DELETE FROM arcana_documents WHERE id = $1", [
        Ecto.UUID.dump!(doc.id)
      ])

      assert {:error, :not_found} = Arcana.delete(doc.id, repo: Repo)
    end
  end

  describe "the delete and the sweep are one unit" do
    test "chunks go with the document" do
      doc = ingest_doc("Elixir runs on the BEAM virtual machine, which is Erlang's.")

      assert Repo.aggregate(
               from(c in Arcana.Chunk, where: c.document_id == ^doc.id),
               :count
             ) > 0

      assert :ok = Arcana.delete(doc.id, repo: Repo)

      assert Repo.aggregate(
               from(c in Arcana.Chunk, where: c.document_id == ^doc.id),
               :count
             ) == 0
    end
  end
end
