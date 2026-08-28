defmodule Arcana.RetrievalScope do
  @moduledoc false

  import Ecto.Query

  alias Arcana.{Chunk, Document}
  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship, RelationshipEvidence}

  @doc false
  def documents do
    from(d in Document,
      as: :document,
      where: d.status == :completed
    )
  end

  @doc false
  def chunks do
    from(c in Chunk,
      as: :chunk,
      join: d in Document,
      as: :document,
      on: d.id == c.document_id,
      where: d.status == :completed
    )
  end

  @doc false
  def mentions do
    from(m in EntityMention,
      as: :mention,
      join: c in Chunk,
      as: :chunk,
      on: c.id == m.chunk_id,
      join: d in Document,
      as: :document,
      on: d.id == c.document_id,
      where: d.status == :completed
    )
  end

  @doc false
  def entities do
    published_mention =
      from([mention: m] in mentions(),
        where: m.entity_id == parent_as(:entity).id
      )

    from(e in Entity,
      as: :entity,
      where: exists(subquery(published_mention))
    )
  end

  @doc false
  def relationships(source_id \\ nil) do
    evidence =
      from(e in RelationshipEvidence,
        join: c in Chunk,
        on: c.id == e.chunk_id,
        join: d in Document,
        on: d.id == c.document_id,
        where:
          e.relationship_id == parent_as(:relationship).id and
            d.status == :completed
      )

    evidence =
      if source_id do
        from([e, c, d] in evidence, where: d.source_id == ^source_id)
      else
        evidence
      end

    from(r in Relationship,
      as: :relationship,
      where: exists(subquery(evidence))
    )
  end

  @doc false
  def communities do
    published_entity =
      from([entity: e] in entities(),
        where: fragment("? = ANY(?)", e.id, parent_as(:community).entity_ids)
      )

    from(c in Community,
      as: :community,
      where: exists(subquery(published_entity))
    )
  end
end
