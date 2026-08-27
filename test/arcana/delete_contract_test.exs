defmodule Arcana.DeleteContractTest do
  @moduledoc """
  `Arcana.delete/2` returning what its docs promise.

  It used to call `repo.delete!/1`, so a foreign key violation or a
  concurrent delete escaped as an exception from a function documenting
  `:ok | {:error, :not_found} | {:error, {:sweep_failed, _}}`. The damage was
  not the exception itself but the sequencing around it: callers remove an
  external artifact and then call this, and a three-clause `case` written
  from the docs gave them no reason to expect control to leave abruptly.

  The cases needing a host table with a foreign key onto `arcana_documents`
  live in `Arcana.DeleteContractDDLTest` instead, because creating that
  constraint takes a `ShareRowExclusiveLock` on `arcana_documents` for the
  whole test and would serialize every async test that writes documents.
  """
  use Arcana.DataCase, async: true

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

    test "a document deleted out from under us reads as :not_found" do
      # This lands on the repo.get/2 branch, not the Ecto.StaleEntryError
      # rescue: the row is already gone by the time delete/2 looks for it.
      # Forcing the actual race - present at the lookup, gone at the delete -
      # needs an interleave inside delete/2 that the sandbox cannot arrange,
      # so the rescue itself is defensive and uncovered. It reports the same
      # :not_found either way, which is the contract being pinned here.
      doc = ingest_doc()

      Repo.delete_all(from(c in Arcana.Chunk, where: c.document_id == ^doc.id))
      Repo.delete_all(from(d in Arcana.Document, where: d.id == ^doc.id))

      assert {:error, :not_found} = Arcana.delete(doc.id, repo: Repo)
    end
  end

  describe "inside a caller's own transaction" do
    test "a failed sweep does not destroy the caller's transaction" do
      # repo.rollback/1 in a nested Ecto transaction aborts the OUTERMOST one,
      # so opening a transaction here unconditionally killed the caller's while
      # handing back a tuple that reads like a recoverable refusal.
      extractor = fn _t, _o -> {:ok, [%{name: "Alpha", type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        graph_store: Arcana.FailingSweepGraphStore,
        collection: "delete-contract-sweep"
      ]

      {:ok, doc} = Arcana.ingest("alpha", Keyword.put(opts, :entity_extractor, extractor))

      result =
        Repo.transaction(fn ->
          deleted = Arcana.delete(doc.id, opts)

          # Still able to work: the point is the caller keeps their transaction.
          {deleted, Repo.aggregate(Arcana.Document, :count)}
        end)

      assert {:ok, {{:error, {:sweep_failed, :sweep_boom}}, _count}} = result
    end
  end

  describe "the delete and the sweep are one unit" do
    test "chunks go with the document" do
      doc = ingest_doc("Elixir runs on the BEAM virtual machine, which is Erlang's.")

      chunks = fn ->
        Repo.aggregate(from(c in Arcana.Chunk, where: c.document_id == ^doc.id), :count)
      end

      assert chunks.() > 0

      assert :ok = Arcana.delete(doc.id, repo: Repo)

      assert chunks.() == 0
    end

    test "a failed sweep puts the chunks back too, not just the document" do
      # A rollback restoring the document without its chunks would be worse
      # than the old behaviour, which at least left nothing half-deleted.
      extractor = fn _t, _o -> {:ok, [%{name: "Beta", type: "concept"}]} end

      opts = [
        repo: Repo,
        graph: true,
        graph_store: Arcana.FailingSweepGraphStore,
        collection: "delete-contract-chunks"
      ]

      {:ok, doc} =
        Arcana.ingest(
          "beta content that is long enough to chunk",
          Keyword.put(opts, :entity_extractor, extractor)
        )

      chunks = fn ->
        Repo.aggregate(from(c in Arcana.Chunk, where: c.document_id == ^doc.id), :count)
      end

      before = chunks.()
      assert before > 0

      assert {:error, {:sweep_failed, :sweep_boom}} = Arcana.delete(doc.id, opts)

      assert Repo.get(Arcana.Document, doc.id), "the document comes back"
      assert chunks.() == before, "and so do its chunks"
    end
  end
end
