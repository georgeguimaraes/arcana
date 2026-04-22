defmodule Arcana.VectorStore.Pgvector do
  @moduledoc """
  PostgreSQL pgvector-backed vector store.

  This is the default vector store backend, using the existing Arcana
  schema with pgvector extension for similarity search.

  ## Breaking name change

  In v1.7 the hybrid-search opts `:semantic_weight` and `:fulltext_weight`
  were renamed to `:vector_weight` and `:keyword_weight`. The old names
  are no longer accepted: callers passing them get a `Logger.warning`
  and the default 0.5 weight.

  ## Configuration

      config :arcana, vector_store: :pgvector  # default

  ## Notes

  This backend works with the existing `arcana_chunks` and `arcana_documents`
  tables. The collection parameter maps to the document's collection_id.

  For simpler use cases without the full document schema, consider the
  `:memory` backend.
  """

  @behaviour Arcana.VectorStore

  alias Arcana.{Chunk, Collection, Document}

  import Ecto.Query

  @impl true
  def store(collection, id, embedding, metadata, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Get or create collection
    {:ok, coll} = Collection.get_or_create(collection, repo)

    # For standalone vector storage, we create a minimal document
    document_id = Keyword.get(opts, :document_id)

    document_id =
      if document_id do
        document_id
      else
        {:ok, doc} =
          %Document{}
          |> Document.changeset(%{
            content: metadata[:text] || "",
            status: :completed,
            collection_id: coll.id,
            metadata: %{vector_store_managed: true}
          })
          |> repo.insert()

        doc.id
      end

    # Insert or update chunk
    case repo.get(Chunk, id) do
      nil ->
        %Chunk{}
        |> Chunk.changeset(%{
          id: id,
          text: metadata[:text] || "",
          embedding: embedding,
          metadata: Map.delete(metadata, :text),
          document_id: document_id
        })
        |> repo.insert()

      existing ->
        existing
        |> Chunk.changeset(%{
          embedding: embedding,
          metadata: Map.delete(metadata, :text)
        })
        |> repo.update()
    end
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def search(collection, query_embedding, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    threshold = Keyword.get(opts, :threshold, 0.0)
    source_id = Keyword.get(opts, :source_id)

    # Get collection_id if collection name is provided
    collection_id =
      if collection do
        case repo.get_by(Collection, name: collection) do
          nil -> nil
          coll -> coll.id
        end
      end

    base_query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        select: %{
          id: c.id,
          metadata:
            merge(c.metadata, %{
              text: c.text,
              chunk_index: c.chunk_index,
              document_id: c.document_id
            }),
          score: fragment("1 - (? <=> ?)", c.embedding, ^query_embedding)
        },
        where: fragment("1 - (? <=> ?) > ?", c.embedding, ^query_embedding, ^threshold),
        order_by: fragment("? <=> ?", c.embedding, ^query_embedding),
        limit: ^limit
      )

    final_query =
      base_query
      |> maybe_filter_source_id(source_id)
      |> maybe_filter_collection_id(collection_id)

    repo.all(final_query)
  end

  @impl true
  def search_text(collection, query_text, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)

    # Get collection_id if collection name is provided
    collection_id =
      if collection do
        case repo.get_by(Collection, name: collection) do
          nil -> nil
          coll -> coll.id
        end
      end

    base_query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where:
          fragment(
            "to_tsvector('english', ?) @@ plainto_tsquery('english', ?)",
            c.text,
            ^query_text
          ),
        select: %{
          id: c.id,
          metadata:
            merge(c.metadata, %{
              text: c.text,
              chunk_index: c.chunk_index,
              document_id: c.document_id
            }),
          score:
            fragment(
              "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
              c.text,
              ^query_text
            )
        },
        order_by: [
          desc:
            fragment(
              "ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))",
              c.text,
              ^query_text
            )
        ],
        limit: ^limit
      )

    final_query =
      base_query
      |> maybe_filter_source_id(source_id)
      |> maybe_filter_collection_id(collection_id)

    repo.all(final_query)
  end

  @doc """
  Performs hybrid search combining semantic and fulltext search in a single query.

  This approach retrieves all results in one database query, avoiding the issue where
  items ranking moderately in both semantic and fulltext searches might be missed
  by separate queries.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:limit` - Maximum number of results (default: 10)
    * `:source_id` - Filter results to a specific source
    * `:vector_weight` - Weight for vector score (default: 0.5)
    * `:keyword_weight` - Weight for keyword score (default: 0.5)
    * `:threshold` - Minimum combined score threshold (default: 0.0)

  ## Score Normalization

  Vector scores (cosine similarity) naturally range from 0-1. Keyword scores
  (ts_rank) vary based on document content. This function normalizes keyword
  scores using min-max scaling within the result set to ensure fair combination.

  """
  def search_hybrid(collection, query_embedding, query_text, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    warn_deprecated_weight_opts(opts)
    vector_weight = Keyword.get(opts, :vector_weight, 0.5)
    keyword_weight = Keyword.get(opts, :keyword_weight, 0.5)
    threshold = Keyword.get(opts, :threshold, 0.0)

    # Get collection_id if collection name is provided, convert to binary for SQL
    collection_id =
      if collection do
        case repo.get_by(Collection, name: collection) do
          nil ->
            nil

          coll ->
            {:ok, binary_id} = Ecto.UUID.dump(coll.id)
            binary_id
        end
      end

    # Use raw SQL for the hybrid query with CTEs for proper normalization
    sql = """
    WITH base_scores AS (
      SELECT
        c.id,
        c.text,
        c.chunk_index,
        c.document_id,
        c.metadata,
        1 - (c.embedding <=> $1) AS vector_score,
        COALESCE(ts_rank(to_tsvector('english', c.text), plainto_tsquery('english', $2)), 0) AS keyword_score
      FROM arcana_chunks c
      JOIN arcana_documents d ON c.document_id = d.id
      WHERE ($3::uuid IS NULL OR d.collection_id = $3::uuid)
        AND ($4::text IS NULL OR d.source_id = $4::text)
    ),
    score_bounds AS (
      SELECT
        MIN(keyword_score) AS min_kw,
        MAX(keyword_score) AS max_kw
      FROM base_scores
    ),
    normalized AS (
      SELECT
        bs.*,
        CASE
          WHEN sb.max_kw = sb.min_kw THEN 0
          ELSE (bs.keyword_score - sb.min_kw) / (sb.max_kw - sb.min_kw)
        END AS keyword_normalized
      FROM base_scores bs, score_bounds sb
    )
    SELECT
      id,
      text,
      chunk_index,
      document_id,
      metadata,
      vector_score,
      keyword_score,
      keyword_normalized,
      ($5::float * vector_score + $6::float * keyword_normalized) AS hybrid_score
    FROM normalized
    WHERE ($5::float * vector_score + $6::float * keyword_normalized) > $7::float
    ORDER BY hybrid_score DESC
    LIMIT $8
    """

    # Pass embedding as Pgvector struct for proper encoding
    embedding_vector = Pgvector.new(query_embedding)

    result =
      repo.query!(sql, [
        embedding_vector,
        query_text,
        collection_id,
        source_id,
        vector_weight,
        keyword_weight,
        threshold,
        limit
      ])

    # Transform rows to result maps
    Enum.map(result.rows, fn row ->
      [
        id,
        text,
        chunk_index,
        document_id,
        metadata,
        vector_score,
        keyword_score,
        _kw_norm,
        hybrid_score
      ] = row

      %{
        id: id,
        metadata:
          Map.merge(metadata || %{}, %{
            text: text,
            chunk_index: chunk_index,
            document_id: document_id,
            vector_score: vector_score,
            keyword_score: keyword_score
          }),
        score: hybrid_score
      }
    end)
  end

  @impl true
  def delete(collection, id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Get collection_id to verify the chunk belongs to the collection
    collection_id =
      if collection do
        case repo.get_by(Collection, name: collection) do
          nil -> nil
          coll -> coll.id
        end
      end

    query =
      from(c in Chunk,
        join: d in Document,
        on: c.document_id == d.id,
        where: c.id == ^id
      )

    query =
      if collection_id do
        from([c, d] in query, where: d.collection_id == ^collection_id)
      else
        query
      end

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      _chunk ->
        repo.delete_all(from(c in Chunk, where: c.id == ^id))
        :ok
    end
  end

  @impl true
  def clear(collection, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.get_by(Collection, name: collection) do
      nil ->
        :ok

      coll ->
        # Delete all chunks in documents belonging to this collection
        chunk_query =
          from(c in Chunk,
            join: d in Document,
            on: c.document_id == d.id,
            where: d.collection_id == ^coll.id
          )

        repo.delete_all(chunk_query)

        # Also delete the documents
        doc_query = from(d in Document, where: d.collection_id == ^coll.id)
        repo.delete_all(doc_query)

        :ok
    end
  end

  # Private helpers

  defp warn_deprecated_weight_opts(opts) do
    cond do
      Keyword.has_key?(opts, :semantic_weight) ->
        require Logger

        Logger.warning(
          "[Arcana.VectorStore.Pgvector] :semantic_weight is deprecated and ignored, " <>
            "use :vector_weight. Passed value was dropped."
        )

      Keyword.has_key?(opts, :fulltext_weight) ->
        require Logger

        Logger.warning(
          "[Arcana.VectorStore.Pgvector] :fulltext_weight is deprecated and ignored, " <>
            "use :keyword_weight. Passed value was dropped."
        )

      true ->
        :ok
    end
  end

  defp maybe_filter_source_id(query, nil), do: query

  defp maybe_filter_source_id(query, source_id) do
    from([c, d] in query, where: d.source_id == ^source_id)
  end

  defp maybe_filter_collection_id(query, nil), do: query

  defp maybe_filter_collection_id(query, collection_id) do
    from([c, d] in query, where: d.collection_id == ^collection_id)
  end
end
