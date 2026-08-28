defmodule Arcana.Migration.SchemaScope do
  @moduledoc false

  alias Arcana.Migration.Registry

  def resolve(_repo, _stream, prefix) when is_binary(prefix), do: prefix

  def resolve(repo, stream, nil) do
    marker_table = Registry.version_table(stream)
    marker_rows = marker_rows(repo, marker_table)

    case marked_schemas(stream, marker_rows) do
      [schema] -> schema
      [] -> resolve_without_marker(repo, stream, marker_table, marker_rows)
      schemas -> raise_ambiguous_markers!(stream, schemas)
    end
  end

  @doc """
  Returns the catalog predicate matching the relation unqualified DDL would
  resolve, or the exact schema selected by an explicit prefix.
  """
  def visible(relation_alias, namespace_alias, parameter) do
    "CASE WHEN #{parameter}::text IS NULL " <>
      "THEN pg_table_is_visible(#{relation_alias}.oid) " <>
      "ELSE #{namespace_alias}.nspname = #{parameter}::text END"
  end

  defp resolve_without_marker(repo, stream, marker_table, marker_rows) do
    owned_tables = List.delete(Registry.owned_tables(stream), marker_table)

    case visible_schemas(repo, owned_tables) do
      [] -> resolve_legacy_marker(stream, marker_rows)
      [schema] -> resolve_complete_legacy(repo, stream, schema)
      schemas -> raise_split_install!(stream, schemas)
    end
  end

  defp resolve_complete_legacy(repo, stream, schema) do
    present = MapSet.new(Registry.present(repo, stream, schema))

    complete? =
      Enum.any?(1..Registry.current_version(stream), fn version ->
        present == MapSet.new(Registry.owned_tables(stream, version))
      end)

    if complete?, do: schema, else: raise_partial_install!(stream, schema)
  end

  defp resolve_legacy_marker(_stream, []), do: nil
  defp resolve_legacy_marker(stream, marker_rows), do: raise_unmarked_marker!(stream, marker_rows)

  defp raise_split_install!(stream, schemas) do
    raise """
    Arcana found #{stream} migration tables spread across multiple visible schemas:

        #{Enum.join(schemas, "\n    ")}

    Nothing was changed. Pass an explicit :prefix for the Arcana install you want to migrate, or repair the partial schemas first.
    """
  end

  defp raise_partial_install!(stream, schema) do
    raise """
    Arcana found an unmarked partial #{stream} migration install in #{schema}.

    Nothing was changed. Pass an explicit :prefix to adopt that schema, or repair the partial install first.
    """
  end

  defp raise_unmarked_marker!(stream, rows) do
    schemas = Enum.map(rows, fn [schema, _comment] -> schema end)

    raise """
    Arcana found an unmarked table named like its #{stream} migration marker in:

        #{Enum.join(schemas, "\n    ")}

    Nothing was changed. Pass an explicit :prefix for the Arcana install you want to migrate.
    """
  end

  defp marker_rows(repo, marker_table) do
    %{rows: rows} =
      repo.query!(
        "SELECT n.nspname, obj_description(c.oid) FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = $1 AND c.relkind IN ('r', 'p') " <>
          "AND n.nspname = ANY(current_schemas(true)) " <>
          "ORDER BY array_position(current_schemas(true), n.nspname)",
        [marker_table]
      )

    rows
  end

  defp marked_schemas(stream, rows) do
    for [schema, comment] <- rows,
        Registry.parse_marker(stream, comment) > 0,
        do: schema
  end

  defp raise_ambiguous_markers!(stream, schemas) do
    raise """
    Arcana found multiple marked #{stream} migration installs on the current search path:

        #{Enum.join(schemas, "\n    ")}

    Nothing was changed. Pass an explicit :prefix for the Arcana install you want to migrate.
    """
  end

  defp visible_schemas(repo, tables) do
    %{rows: rows} =
      repo.query!(
        "SELECT DISTINCT n.nspname FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = ANY($1) AND c.relkind IN ('r', 'p') " <>
          "AND pg_table_is_visible(c.oid) ORDER BY n.nspname",
        [tables]
      )

    List.flatten(rows)
  end
end
