defmodule Arcana.Migration.Registry do
  @moduledoc false

  alias Arcana.Migration.SchemaScope

  @streams %{
    core: %{
      marker: %{table: "arcana_documents", namespace: "arcana"},
      versions: %{
        1 => ~w(
          arcana_collections
          arcana_documents
          arcana_chunks
          arcana_evaluation_test_cases
          arcana_evaluation_test_case_chunks
          arcana_evaluation_runs
        )
      }
    },
    graph: %{
      marker: %{table: "arcana_graph_entities", namespace: "arcana_graph"},
      versions: %{
        1 => ~w(
          arcana_graph_entities
          arcana_graph_entity_mentions
          arcana_graph_relationships
          arcana_graph_communities
        ),
        2 => ~w(arcana_graph_relationship_evidence)
      }
    }
  }

  def current_version(stream),
    do: @streams |> stream!(stream) |> Map.fetch!(:versions) |> map_size()

  def version_table(stream), do: @streams |> stream!(stream) |> get_in([:marker, :table])

  def marker(stream, version) when is_integer(version) and version > 0 do
    namespace = @streams |> stream!(stream) |> get_in([:marker, :namespace])
    "#{namespace}:#{version}"
  end

  def parse_marker(stream, comment) when is_binary(comment) do
    namespace = @streams |> stream!(stream) |> get_in([:marker, :namespace])

    case Regex.run(~r/\A#{Regex.escape(namespace)}:(\d+)\z/, String.trim(comment)) do
      [_, version] -> String.to_integer(version)
      _ -> 0
    end
  end

  def parse_marker(_stream, nil), do: 0

  def tables_added_in(stream, version) do
    @streams |> stream!(stream) |> Map.fetch!(:versions) |> Map.fetch!(version)
  end

  def owned_tables(stream, target \\ nil) do
    target = target || current_version(stream)

    1..target
    |> Enum.flat_map(&tables_added_in(stream, &1))
  end

  def present(repo, stream, prefix) do
    %{rows: rows} =
      repo.query!(
        "SELECT c.relname FROM pg_class c " <>
          "JOIN pg_namespace n ON n.oid = c.relnamespace " <>
          "WHERE c.relname = ANY($1) AND c.relkind IN ('r', 'p') " <>
          "AND " <> SchemaScope.visible("c", "n", "$2"),
        [owned_tables(stream), prefix]
      )

    List.flatten(rows)
  end

  defp stream!(streams, stream), do: Map.fetch!(streams, stream)
end
