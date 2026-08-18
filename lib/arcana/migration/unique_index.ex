defmodule Arcana.Migration.UniqueIndex do
  @moduledoc false

  # Shared by `Arcana.Migration` and `Arcana.Graph.Migration`, which each own
  # unique indexes that adoption has to verify rather than merely create.
  #
  # `create_if_not_exists` matches on the index *name*, and these use Ecto's
  # default names, so an older install almost certainly has one already. If a
  # previous template created it non-unique, over different columns, partial,
  # or over an expression, Postgres skips creation and reports success -
  # leaving an adopted database without the constraint a fresh one gets. That
  # doesn't error, it lets duplicates accumulate.
  #
  # This module both drops and rebuilds. An earlier version dropped here and
  # relied on the `create_if_not_exists` inside `change(1, :up, _)` to rebuild,
  # which is skipped once the recorded version already equals the target - so
  # the index was dropped and never replaced.

  require Logger

  @doc """
  Ensures `table` has a plain unique index on `columns`, rebuilding one that
  exists under the same name with a different shape.
  """
  def converge!(repo, table, columns, prefix, qualify) do
    name = Enum.join([table | columns] ++ ["index"], "_")

    # This runs from up/1, before the version comparison, so on a fresh
    # install the table does not exist yet. Creating an index on it would
    # fail; the create inside change(1, :up, _) makes both together.
    if table_exists?(repo, table, prefix) do
      converge_existing!(repo, name, table, columns, prefix, qualify)
    else
      :ok
    end
  end

  defp converge_existing!(repo, name, table, columns, prefix, qualify) do
    case describe(repo, name, table, prefix) do
      nil ->
        create_absent!(repo, name, table, columns, prefix, qualify)

      %{
        unique: true,
        partial: false,
        expression: false,
        valid: true,
        ready: true,
        columns: ^columns
      } ->
        :ok

      existing ->
        rebuild!(repo, name, table, columns, existing, prefix, qualify)
    end
  end

  defp table_exists?(repo, table, prefix) do
    %{rows: [[count]]} =
      repo.query!(
        "SELECT count(*) FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND c.relkind IN ('r', 'p') " <>
          "AND n.nspname = COALESCE($2, current_schema())",
        [table, prefix]
      )

    count > 0
  end

  # A partial index carries the right columns but only constrains the rows
  # matching its predicate, and an expression index does not constrain the raw
  # columns at all. Both would pass a naive comparison.
  defp describe(repo, name, table, prefix) do
    %{rows: rows} =
      repo.query!(
        # Group by the boolean, not by indpred itself: grouping a
        # pg_node_tree only works because it is implicitly binary-coercible
        # to text, which is not a guarantee worth leaning on.
        "SELECT i.indisunique, i.indpred IS NOT NULL, " <>
          "0 = ANY(i.indkey::int2[]), i.indisvalid, i.indisready, " <>
          "array_agg(a.attname::text ORDER BY k.ord) " <>
          "FROM pg_index i " <>
          "JOIN pg_class ic ON ic.oid = i.indexrelid " <>
          "JOIN pg_class tc ON tc.oid = i.indrelid " <>
          "JOIN pg_namespace n ON n.oid = tc.relnamespace " <>
          "LEFT JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON true " <>
          "LEFT JOIN pg_attribute a ON a.attrelid = tc.oid AND a.attnum = k.attnum " <>
          "WHERE ic.relname = $1 AND tc.relname = $2 " <>
          "AND n.nspname = COALESCE($3, current_schema()) " <>
          "GROUP BY i.indisunique, i.indpred IS NOT NULL, i.indkey, " <>
          "i.indisvalid, i.indisready",
        [name, table, prefix]
      )

    case rows do
      [] ->
        nil

      [[unique, partial, expression, valid, ready, cols]] ->
        %{
          unique: unique,
          partial: partial,
          expression: expression,
          valid: valid,
          ready: ready,
          columns: Enum.reject(cols || [], &is_nil/1)
        }
    end
  end

  # An index that is missing entirely needs the same duplicate check the
  # rebuild path does. Without it the CREATE below surfaces a raw
  # Postgrex.Error unique violation rather than the explanation this module
  # promises - and a table whose index was manually dropped is exactly the
  # kind of drifted install adoption exists to handle.
  defp create_absent!(repo, name, table, columns, prefix, qualify) do
    lock!(repo, table, qualify)

    case duplicates(repo, table, columns, prefix, qualify) do
      [] ->
        create!(repo, name, table, columns, qualify)

      dupes ->
        refuse!(name, table, columns, dupes, "It is missing, so nothing enforced uniqueness")
    end
  end

  defp rebuild!(repo, name, table, columns, existing, prefix, qualify) do
    lock!(repo, table, qualify)

    case duplicates(repo, table, columns, prefix, qualify) do
      [] ->
        repo.query!("DROP INDEX #{qualify.(name)}")
        create!(repo, name, table, columns, qualify)

        Logger.info("""
        Arcana rebuilt #{name} on #{table}: it existed as #{shape(existing)}, \
        and this version needs a plain unique index on #{inspect(columns)}.
        """)

      dupes ->
        refuse!(
          name,
          table,
          columns,
          dupes,
          "It already exists as #{shape(existing)}, so it never enforced uniqueness"
        )
    end
  end

  defp refuse!(name, table, columns, dupes, cause) do
    raise """
    Arcana can't add the unique index #{name} on #{table}.

    #{cause}, and these #{inspect(columns)} values are duplicated as a \
    result:

    #{Enum.map_join(dupes, "\n", fn row -> "    " <> inspect(row) end)}

    Nothing was changed. Resolve the duplicates and run the migration \
    again. Arcana won't delete them for you: on this table that cascades \
    to rows it does not own.
    """
  end

  # Without this, a write committing between the duplicate preflight and the
  # CREATE turns the explained refusal back into a raw Postgrex error. SHARE
  # conflicts with the ROW EXCLUSIVE that writers take, and CREATE UNIQUE
  # INDEX takes SHARE anyway, so this only moves that lock earlier - the
  # converge paths that change nothing never reach it. Ecto runs migrations in
  # a transaction, which is what makes the lock outlive this statement.
  defp lock!(repo, table, qualify) do
    repo.query!("LOCK TABLE #{qualify.(table)} IN SHARE MODE")
  end

  # Only creates when absent, so this is safe to call on the no-index path and
  # after a drop alike.
  #
  # The index name is bare while the table stays qualified: CREATE INDEX takes
  # no schema on the name and rejects one outright, and it puts the index in
  # the table's schema regardless. DROP INDEX is the opposite - it names the
  # index and not the table - which is why rebuild! qualifies there.
  defp create!(repo, name, table, columns, qualify) do
    cols = Enum.map_join(columns, ", ", &quoted/1)

    repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{quoted(name)} ON #{qualify.(table)} (#{cols})"
    )

    :ok
  end

  # A double quote inside an identifier is escaped by doubling it, the same way
  # the migration modules' own qualify/2 does it.
  defp quoted(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")

  # Postgres treats NULLs as distinct in a unique index, so rows with a NULL in
  # any key column never collide and must not count as duplicates here - a
  # GROUP BY would otherwise group them together and block a migration that
  # would in fact succeed.
  defp duplicates(repo, table, columns, prefix, qualify) do
    cols = Enum.map_join(columns, ", ", &quoted/1)
    not_null = Enum.map_join(columns, " AND ", &(quoted(&1) <> " IS NOT NULL"))

    %{rows: rows} =
      repo.query!(
        "SELECT #{cols} FROM #{qualify.(table)} WHERE #{not_null} " <>
          "GROUP BY #{cols} HAVING count(*) > 1 LIMIT 10",
        []
      )

    rows
  end

  defp shape(%{unique: unique, partial: partial, expression: expression, columns: cols} = idx) do
    [
      # An index left behind by a failed CREATE INDEX CONCURRENTLY is present
      # and correctly shaped but enforces nothing.
      if(idx[:valid] == false, do: "invalid", else: nil),
      if(idx[:ready] == false, do: "not ready", else: nil),
      if(unique, do: "unique", else: "non-unique"),
      if(partial, do: "partial", else: nil),
      if(expression, do: "over an expression", else: "on #{inspect(cols)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
