defmodule Arcana.Migration.SchemaScope do
  @moduledoc false

  alias Arcana.Migration.Registry

  def resolve(_repo, _stream, prefix) when is_binary(prefix), do: prefix

  def resolve(repo, stream, nil) do
    marker_table = Registry.version_table(stream)

    case visible_schemas(repo, [marker_table]) do
      [schema] -> schema
      [] -> resolve_from_owned_tables(repo, stream)
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

  defp resolve_from_owned_tables(repo, stream) do
    case visible_schemas(repo, Registry.owned_tables(stream)) do
      [] ->
        nil

      [schema] ->
        schema

      schemas ->
        raise """
        Arcana found #{stream} migration tables spread across multiple visible schemas:

            #{Enum.join(schemas, "\n    ")}

        Nothing was changed. Pass an explicit :prefix for the Arcana install you want to migrate, or repair the partial schemas first.
        """
    end
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
