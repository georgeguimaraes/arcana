defmodule Arcana.VectorStore.HnswIndexDefinitionTest do
  @moduledoc """
  Guards the HNSW indexes the production search path plans against.

  `enable_indexscan: "off"` on the test repo (see config/test.exs) means no test
  ever plans an index scan, so without this nothing would notice one of these
  indexes being dropped, moved to another column, or rebuilt with the wrong
  operator class - it would just silently seq-scan and pass.

  It asserts the definitions rather than query results through an index scan,
  and that is deliberate. Rolling back does not remove an entry from an HNSW
  index, so the shared `arcana_chunks` index carries every other test's debris
  for a whole run. Forcing an index scan against it exhausts the traversal
  budget among invisible entries and returns zero rows for data that is plainly
  visible - measured: 5000 in-flight neighbours starve it even when the query
  direction is orthogonal to them, because `hnsw.ef_search` bounds graph
  traversal effort, not distance. That is precisely the flake this config
  removed, so asserting through it would reintroduce it inside the test meant to
  guard it. Whether HNSW returns the right rows for a given scan is pgvector's
  business; that our schema still ships the right index is ours.
  """
  use Arcana.DataCase, async: true

  alias Ecto.Adapters.SQL

  # arcana_graph_entities is partial: the graph migration only indexes rows that
  # actually carry an embedding.
  @indexes [
    {"arcana_chunks", "arcana_chunks_embedding_idx", nil},
    {"arcana_graph_entities", "arcana_graph_entities_embedding_idx",
     "WHERE (embedding IS NOT NULL)"}
  ]

  for {table, index, predicate} <- @indexes do
    test "#{index} is an hnsw index over embedding vector_cosine_ops" do
      %{rows: rows} =
        SQL.query!(
          Repo,
          "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() " <>
            "AND tablename = $1 AND indexname = $2",
          [unquote(table), unquote(index)]
        )

      # Checked before destructuring: `assert [[x]] = rows, "msg"` raises a bare
      # MatchError on [] and the message never prints, which loses the only
      # thing that says WHICH index went missing.
      assert rows != [], "#{unquote(index)} is missing from #{unquote(table)}"

      [[indexdef]] = rows

      assert indexdef =~ "USING hnsw",
             "expected an hnsw index, got: #{indexdef}"

      assert indexdef =~ "embedding vector_cosine_ops",
             "cosine search needs vector_cosine_ops on embedding, got: #{indexdef}"

      case unquote(predicate) do
        nil ->
          # Not just "no predicate asserted" - assert there is none. A partial
          # index cannot serve an unpredicated query at all, so one copy-pasted
          # onto this index would take it out of the search path silently.
          refute indexdef =~ " WHERE ",
                 "this index must cover every row, got: #{indexdef}"

        pred ->
          assert indexdef =~ pred, "expected the partial predicate #{pred}, got: #{indexdef}"
      end

      # Shape alone is not health. pg_indexes has no validity predicate and
      # pg_get_indexdef renders an invalid index identically to a live one, but
      # the planner refuses it outright - so an interrupted CREATE INDEX
      # CONCURRENTLY would leave searches seq-scanning with this test green.
      # Arcana.Migration converges exactly this state (see the "an invalid index
      # of the right shape is rebuilt" case in migration_test.exs), so it has to
      # be checked here too. Safe to cast to regclass: the assertion above has
      # already established the index exists.
      %{rows: [[valid]]} =
        SQL.query!(
          Repo,
          "SELECT indisvalid AND indisready FROM pg_index WHERE indexrelid = $1::text::regclass",
          [unquote(index)]
        )

      assert valid, "#{unquote(index)} exists but is not valid and ready, so nothing will use it"
    end
  end
end
