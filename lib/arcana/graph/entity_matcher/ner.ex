defmodule Arcana.Graph.EntityMatcher.NER do
  @moduledoc """
  Entity matcher that extracts entity names from the query and looks them
  up by exact name match in the graph.

  Uses the configured `Arcana.Graph.EntityExtractor` (defaults to NER via
  Bumblebee) to identify named entities in the query, then performs a case
  sensitive name lookup in the entities table.

  This matcher works best when queries name entities directly. It tends to
  outperform embedding similarity on queries with proper nouns. It cannot
  match entities the extractor doesn't identify in the query text.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:entity_extractor` - override the configured entity extractor
  """

  @behaviour Arcana.Graph.EntityMatcher

  import Ecto.Query

  alias Arcana.Graph.{Entity, EntityExtractor}

  @impl Arcana.Graph.EntityMatcher
  def match(query, collection_ids, opts) do
    repo = Keyword.fetch!(opts, :repo)
    extractor = Arcana.Graph.resolve_entity_extractor(opts)

    with {:ok, entities} when entities != [] <- EntityExtractor.extract(extractor, query) do
      entity_names = Enum.map(entities, & &1.name)
      {:ok, lookup_ids_by_name(entity_names, collection_ids, repo)}
    else
      _ -> {:ok, []}
    end
  end

  defp lookup_ids_by_name(entity_names, collection_ids, repo) do
    query = from(e in Entity, where: e.name in ^entity_names, select: e.id)

    query =
      if collection_ids && collection_ids != [] do
        from(e in query, where: e.collection_id in ^collection_ids)
      else
        query
      end

    repo.all(query)
  end
end
