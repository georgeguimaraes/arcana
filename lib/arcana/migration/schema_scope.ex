defmodule Arcana.Migration.SchemaScope do
  @moduledoc """
  One rule for "is this catalog row the object our DDL would actually touch".

  Every migration module looks itself up in `pg_class` to decide what is
  installed. They all used to scope that with `n.nspname = COALESCE($n,
  current_schema())`, which is wrong for the unprefixed case:
  `current_schema()` is only the *first* entry of `search_path`, while an
  unqualified `CREATE`/`DROP`/`SELECT` resolves through the whole path.

  On the supported multi-tenant layout — `search_path = tenant, public` with
  Arcana's tables in `public` — those lookups reported nothing while the DDL
  right next to them resolved to `public` and worked. `Arcana.Migration.down/1`
  read version 0 from it, concluded nothing was installed, and returned `:ok`
  having dropped nothing: silently declining the operator's request, which is
  the failure `refuse_blind_rollback!/1` exists to prevent.

  `pg_table_is_visible/1` answers the question the DDL actually asks. With an
  explicit `:prefix` the schema is named outright and there is nothing to
  resolve, so that case still compares `nspname`.

  `Arcana.Graph.installed?/2` reached this conclusion first and carries the
  same comment; this is that fix applied to the rest of the family.
  """

  @doc """
  A SQL predicate scoping a `pg_class` row to the migration's target schema.

  `rel` and `ns` are the query's aliases for `pg_class` and `pg_namespace`,
  and `param` is the placeholder holding the prefix (`nil` for unprefixed).
  All three are compile-time literals from the calling query, never input.
  """
  def visible(rel, ns, param) do
    "CASE WHEN #{param}::text IS NULL " <>
      "THEN pg_table_is_visible(#{rel}.oid) " <>
      "ELSE #{ns}.nspname = #{param}::text END"
  end
end
