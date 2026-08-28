defmodule Arcana.Migration.Dependencies do
  @moduledoc false

  alias Arcana.Migration.Registry
  alias Arcana.Migration.SchemaScope

  def external(repo, stream, prefix) do
    tables = Registry.owned_tables(stream)

    (foreign_keys(repo, tables, prefix) ++
       views(repo, tables, prefix) ++
       composite_columns(repo, tables, prefix) ++
       inherited_tables(repo, tables, prefix) ++
       extension_memberships(repo, tables, prefix) ++
       generic_dependencies(repo, tables, prefix))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp foreign_keys(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        owned_cte() <>
          "SELECT 'foreign key', source_ns.nspname, source.relname, con.conname, " <>
          "target_ns.nspname, target.relname " <>
          "FROM pg_constraint con " <>
          "JOIN owned ON owned.oid = con.confrelid " <>
          "JOIN pg_class source ON source.oid = con.conrelid " <>
          "JOIN pg_namespace source_ns ON source_ns.oid = source.relnamespace " <>
          "JOIN pg_class target ON target.oid = con.confrelid " <>
          "JOIN pg_namespace target_ns ON target_ns.oid = target.relnamespace " <>
          "WHERE con.contype = 'f' AND NOT EXISTS " <>
          "(SELECT 1 FROM owned source_owned WHERE source_owned.oid = con.conrelid)",
        [tables, prefix]
      )

    Enum.map(rows, fn [kind, schema, table, name, target_schema, target] ->
      ~s(#{kind} #{quote_ident(schema)}.#{quote_ident(table)}.#{quote_ident(name)} -> #{quote_ident(target_schema)}.#{quote_ident(target)})
    end)
  end

  defp views(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        owned_cte() <>
          "SELECT DISTINCT CASE view.relkind WHEN 'm' THEN 'materialized view' ELSE 'view' END, " <>
          "view_ns.nspname, view.relname, target_ns.nspname, target.relname " <>
          "FROM pg_depend dep " <>
          "JOIN pg_rewrite rewrite ON rewrite.oid = dep.objid " <>
          "JOIN pg_class view ON view.oid = rewrite.ev_class " <>
          "JOIN pg_namespace view_ns ON view_ns.oid = view.relnamespace " <>
          "JOIN owned ON owned.oid = dep.refobjid " <>
          "JOIN pg_class target ON target.oid = owned.oid " <>
          "JOIN pg_namespace target_ns ON target_ns.oid = target.relnamespace " <>
          "WHERE dep.classid = 'pg_rewrite'::regclass " <>
          "AND dep.refclassid = 'pg_class'::regclass AND dep.deptype = 'n' " <>
          "AND view.relkind IN ('v', 'm') " <>
          "AND NOT EXISTS (SELECT 1 FROM owned view_owned WHERE view_owned.oid = view.oid)",
        [tables, prefix]
      )

    Enum.map(rows, fn [kind, schema, view, target_schema, target] ->
      ~s(#{kind} #{quote_ident(schema)}.#{quote_ident(view)} -> #{quote_ident(target_schema)}.#{quote_ident(target)})
    end)
  end

  defp composite_columns(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        owned_cte() <>
          "SELECT host_ns.nspname, host.relname, attr.attname, " <>
          "target_ns.nspname, target.relname " <>
          "FROM pg_attribute attr " <>
          "JOIN pg_class host ON host.oid = attr.attrelid " <>
          "JOIN pg_namespace host_ns ON host_ns.oid = host.relnamespace " <>
          "JOIN owned ON owned.reltype = attr.atttypid " <>
          "JOIN pg_class target ON target.oid = owned.oid " <>
          "JOIN pg_namespace target_ns ON target_ns.oid = target.relnamespace " <>
          "WHERE attr.attnum > 0 AND NOT attr.attisdropped " <>
          "AND NOT EXISTS (SELECT 1 FROM owned host_owned WHERE host_owned.oid = host.oid)",
        [tables, prefix]
      )

    Enum.map(rows, fn [schema, table, column, target_schema, target] ->
      ~s(column #{quote_ident(schema)}.#{quote_ident(table)}.#{quote_ident(column)} uses row type #{quote_ident(target_schema)}.#{quote_ident(target)})
    end)
  end

  defp inherited_tables(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        owned_cte() <>
          "SELECT child_ns.nspname, child.relname, parent_ns.nspname, parent.relname " <>
          "FROM pg_inherits inheritance " <>
          "JOIN owned ON owned.oid = inheritance.inhparent " <>
          "JOIN pg_class child ON child.oid = inheritance.inhrelid " <>
          "JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace " <>
          "JOIN pg_class parent ON parent.oid = inheritance.inhparent " <>
          "JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace " <>
          "WHERE NOT EXISTS (SELECT 1 FROM owned child_owned WHERE child_owned.oid = child.oid)",
        [tables, prefix]
      )

    Enum.map(rows, fn [schema, child, parent_schema, parent] ->
      ~s(inherited table #{quote_ident(schema)}.#{quote_ident(child)} -> #{quote_ident(parent_schema)}.#{quote_ident(parent)})
    end)
  end

  defp generic_dependencies(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        dependency_cte() <>
          "SELECT DISTINCT identified.type, identified.schema, identified.identity " <>
          "FROM pg_depend dependency " <>
          "CROSS JOIN LATERAL pg_identify_object(" <>
          "dependency.classid, dependency.objid, dependency.objsubid) identified " <>
          "WHERE dependency.deptype IN ('n', 'a') AND (" <>
          "(dependency.refclassid = 'pg_class'::regclass " <>
          "AND dependency.refobjid IN (SELECT oid FROM owned)) OR " <>
          "(dependency.refclassid = 'pg_type'::regclass " <>
          "AND dependency.refobjid IN (SELECT oid FROM dependent_types))) " <>
          "AND NOT (dependency.classid = 'pg_constraint'::regclass " <>
          "AND dependency.objid IN (SELECT con.oid FROM pg_constraint con " <>
          "WHERE con.conrelid IN (SELECT oid FROM owned))) " <>
          "AND NOT (dependency.classid = 'pg_rewrite'::regclass " <>
          "AND dependency.objid IN (SELECT rewrite.oid FROM pg_rewrite rewrite " <>
          "WHERE rewrite.ev_class IN (SELECT oid FROM owned))) " <>
          "AND NOT (dependency.deptype = 'a' " <>
          "AND dependency.classid = 'pg_attrdef'::regclass " <>
          "AND dependency.objid IN (SELECT def.oid FROM pg_attrdef def " <>
          "WHERE def.adrelid IN (SELECT oid FROM owned))) " <>
          "AND NOT (dependency.deptype = 'a' " <>
          "AND dependency.classid = 'pg_class'::regclass " <>
          "AND dependency.objid IN (SELECT idx.indexrelid FROM pg_index idx " <>
          "WHERE idx.indrelid IN (SELECT oid FROM owned))) " <>
          "AND NOT (dependency.classid = 'pg_class'::regclass " <>
          "AND dependency.objid IN (SELECT oid FROM owned))",
        [tables, prefix]
      )

    Enum.map(rows, fn [type, schema, identity] ->
      schema_part = if schema, do: " in #{quote_ident(schema)}", else: ""
      "#{type} #{identity}#{schema_part}"
    end)
  end

  defp extension_memberships(repo, tables, prefix) do
    %{rows: rows} =
      repo.query!(
        owned_cte() <>
          "SELECT extension.extname, target_ns.nspname, target.relname " <>
          "FROM pg_depend dependency " <>
          "JOIN owned ON owned.oid = dependency.objid " <>
          "JOIN pg_extension extension ON extension.oid = dependency.refobjid " <>
          "JOIN pg_class target ON target.oid = owned.oid " <>
          "JOIN pg_namespace target_ns ON target_ns.oid = target.relnamespace " <>
          "WHERE dependency.classid = 'pg_class'::regclass " <>
          "AND dependency.refclassid = 'pg_extension'::regclass " <>
          "AND dependency.deptype = 'e'",
        [tables, prefix]
      )

    Enum.map(rows, fn [extension, schema, table] ->
      ~s(extension #{quote_ident(extension)} requires #{quote_ident(schema)}.#{quote_ident(table)})
    end)
  end

  defp owned_cte do
    "WITH owned AS (" <>
      "SELECT c.oid, c.reltype FROM pg_class c " <>
      "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
      "WHERE c.relname = ANY($1) AND c.relkind IN ('r', 'p') " <>
      "AND " <> SchemaScope.visible("c", "n", "$2") <> ") "
  end

  defp dependency_cte do
    "WITH RECURSIVE owned AS (" <>
      "SELECT c.oid, c.reltype FROM pg_class c " <>
      "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
      "WHERE c.relname = ANY($1) AND c.relkind IN ('r', 'p') " <>
      "AND " <>
      SchemaScope.visible("c", "n", "$2") <>
      "), dependent_types(oid) AS (" <>
      "SELECT reltype FROM owned UNION " <>
      "SELECT type.oid FROM pg_type type JOIN dependent_types dependency " <>
      "ON type.typbasetype = dependency.oid OR type.typelem = dependency.oid) "
  end

  defp quote_ident(identifier), do: ~s("#{String.replace(identifier, ~s("), ~s(""))}")
end
