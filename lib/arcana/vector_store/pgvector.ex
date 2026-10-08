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

  ## How hybrid blends the two scores

  `:hybrid` mode scores each chunk on cosine similarity and on keyword
  coverage, then blends them by `:vector_weight` and `:keyword_weight`.

  Keyword coverage is the share of the query's distinct terms (lexemes after
  stemming and stopword removal) that a chunk contains: a chunk with three of a
  query's four terms scores 0.75. It is already on a 0 to 1 scale, so it needs no
  normalization against the candidate set, and repeating a term does not raise it.

  Two earlier designs failed in opposite ways. Ranking by `ts_rank` let a chunk
  that repeats a few query terms outrank the chunk that answers the query (#166).
  Gating on the AND query from `plainto_tsquery` fixed that, but a chunk must then
  carry every term, so a query longer than a few words matched nothing and hybrid
  ran as vector search alone. Coverage keeps partial matches and ranks a chunk
  that carries more of the query above one that repeats less of it.

  `:keyword_score_floor` scaled `ts_rank` scores and has no effect now. It is
  deprecated and ignored.

  ## Tuning recall with :hnsw_ef_search

  An HNSW index scan considers `hnsw.ef_search` candidates and only then applies
  the query's filters, so a search scoped to a collection or a source can come
  back with fewer rows than exist - occasionally none. pgvector's default is 40.
  Raising it finds more of the true nearest neighbours, at the cost of more work
  per query:

      Arcana.search("question", collection: ["docs"], hnsw_ef_search: 200)

  It can also be a global search default:

      config :arcana, search: [hnsw_ef_search: 200]

  Three things worth knowing. It only applies when the planner actually chooses
  an index scan - on a small table a sequential scan is exact and the setting is
  irrelevant. Because `hnsw.ef_search` is a GUC, applying it means running the
  search inside a transaction; if you already have one open, the setting stays in
  effect for the rest of *your* transaction rather than just the search.

  And it costs a round-trip. Setting it adds a transaction and one `set_config`
  query per search, and `Arcana.search/2` searches each collection separately -
  so a query over three collections pays it three times, and as a global default
  it applies to every search. That is deliberate rather than hoisted up to wrap
  the whole retrieval: retrieval also embeds the query, and holding a database
  transaction open across a call to an embedding service is worse than an extra
  round-trip. Set it per call on the searches that need the recall, rather than
  globally, if that matters to you.

  Applies to the chunk search in `:vector` and `:hybrid` modes. `:keyword` never
  touches the vector index, so it ignores the option.

  It does not reach the graph paths. `Arcana.Graph.GraphStore.Ecto`'s entity
  search runs its own filtered query against `arcana_graph_entities`' HNSW index,
  so with `graph: true` (or `Arcana.ask/2`'s graph context) the chunk search
  honours the option while the entity match can still under-return. Extending it
  there is a separate change.

  ## Notes

  This backend works with the existing `arcana_chunks` and `arcana_documents`
  tables. The collection parameter maps to the document's collection_id.

  For simpler use cases without the full document schema, consider the
  `:memory` backend.
  """

  @behaviour Arcana.VectorStore

  alias Arcana.{Chunk, Collection, Document, RetrievalScope}

  import Ecto.Query

  @impl true
  def store(collection, id, embedding, metadata, opts) do
    repo = Keyword.fetch!(opts, :repo)

    # Auto-create the collection unless strict mode requires it to exist
    case resolve_store_collection(collection, repo, opts) do
      {:ok, coll} -> do_store(coll, id, embedding, metadata, opts, repo)
      {:error, _} = error -> error
    end
  end

  defp resolve_store_collection(collection, repo, opts) do
    if Arcana.Config.strict_collections?(opts) do
      Collection.fetch(collection, repo)
    else
      Collection.get_or_create(collection, repo)
    end
  end

  defp do_store(coll, id, embedding, metadata, opts, repo) do
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

    # Validated before the collection is resolved: an unknown collection under
    # strict mode returns early, and a bad option should be a bad option either
    # way rather than depending on whether the name happens to exist.
    ef_search = ef_search!(opts)

    case resolve_filter_collection_id(collection, repo, opts) do
      :unknown ->
        []

      {:ok, collection_id} ->
        base_query =
          from([chunk: c] in RetrievalScope.chunks(),
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

        query =
          base_query
          |> maybe_filter_source_id(source_id)
          |> maybe_filter_collection_id(collection_id)

        with_ef_search(repo, ef_search, fn -> repo.all(query) end)
    end
  end

  @impl true
  def search_text(collection, query_text, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)

    case resolve_filter_collection_id(collection, repo, opts) do
      :unknown ->
        []

      {:ok, collection_id} ->
        base_query =
          from([chunk: c] in RetrievalScope.chunks(),
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

        base_query
        |> maybe_filter_source_id(source_id)
        |> maybe_filter_collection_id(collection_id)
        |> repo.all()
    end
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

  ## Scores

  The vector score is cosine similarity. The keyword score is the share of the
  query's distinct terms that the chunk contains, from 0 to 1. See the module
  docs for why.

  """
  def search_hybrid(collection, query_embedding, query_text, opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 10)
    source_id = Keyword.get(opts, :source_id)
    warn_deprecated_opts(opts)
    vector_weight = Keyword.get(opts, :vector_weight, 0.5)
    keyword_weight = Keyword.get(opts, :keyword_weight, 0.5)
    threshold = Keyword.get(opts, :threshold, 0.0)
    ef_search = ef_search!(opts)

    # Resolve the collection filter, converted to binary for raw SQL
    case resolve_filter_collection_id(collection, repo, opts) do
      :unknown ->
        []

      {:ok, resolved_id} ->
        collection_id =
          case resolved_id do
            nil ->
              nil

            id ->
              {:ok, binary_id} = Ecto.UUID.dump(id)
              binary_id
          end

        with_ef_search(repo, ef_search, fn ->
          do_search_hybrid(collection_id, query_embedding, query_text, %{
            repo: repo,
            limit: limit,
            source_id: source_id,
            vector_weight: vector_weight,
            keyword_weight: keyword_weight,
            threshold: threshold
          })
        end)
    end
  end

  defp do_search_hybrid(collection_id, query_embedding, query_text, params) do
    %{
      repo: repo,
      limit: limit,
      source_id: source_id,
      vector_weight: vector_weight,
      keyword_weight: keyword_weight,
      threshold: threshold
    } = params

    sql = """
    WITH q AS (
      SELECT tsvector_to_array(to_tsvector('english', $2)) AS lexemes
    ),
    scored AS (
      SELECT
        c.id,
        c.text,
        c.chunk_index,
        c.document_id,
        c.metadata,
        1 - (c.embedding <=> $1) AS vector_score,
        -- The share of the query's distinct lexemes the chunk contains: ts_delete
        -- drops the query's lexemes from the chunk's tsvector, so the length lost
        -- is how many of them it had. The query's lexemes come out of to_tsvector
        -- already deduplicated, and NULLIF turns a stopword-only query into 0
        -- rather than a division by zero.
        --
        -- Measured on 5k chunks of 120-170 words with a 13-lexeme query: 283ms,
        -- against 278ms for the ts_rank gate this replaced and 347ms for an
        -- unnest/INTERSECT form that gives the same counts.
        COALESCE(
          (length(v.tsv) - length(ts_delete(v.tsv, q.lexemes)))::float
            / NULLIF(cardinality(q.lexemes), 0),
          0
        ) AS keyword_score
      FROM arcana_chunks c
      JOIN arcana_documents d ON c.document_id = d.id
      CROSS JOIN q
      -- OFFSET 0 keeps the tsvector from being inlined into each use and built twice.
      CROSS JOIN LATERAL (SELECT to_tsvector('english', c.text) AS tsv OFFSET 0) v
      WHERE ($3::uuid IS NULL OR d.collection_id = $3::uuid)
        AND ($4::text IS NULL OR d.source_id = $4::text)
        AND d.status = 'completed'
    )
    SELECT
      id,
      text,
      chunk_index,
      document_id,
      metadata,
      vector_score,
      keyword_score,
      ($5::float * vector_score + $6::float * keyword_score) AS hybrid_score
    FROM scored
    WHERE ($5::float * vector_score + $6::float * keyword_score) > $7::float
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
    strict? = Arcana.Config.strict_collections?(opts)

    # Get collection_id to verify the chunk belongs to the collection
    case Collection.resolve_id(collection, repo, strict?) do
      {:ok, collection_id} -> do_delete(collection_id, id, repo)
      {:error, _} = error -> error
    end
  end

  defp do_delete(collection_id, id, repo) do
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
    strict? = Arcana.Config.strict_collections?(opts)

    case repo.get_by(Collection, name: collection) do
      nil when strict? ->
        {:error, {:unknown_collection, collection}}

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

  @deprecated_opts [
    semantic_weight: "use :vector_weight. Passed value was dropped.",
    fulltext_weight: "use :keyword_weight. Passed value was dropped.",
    keyword_score_floor:
      "keyword scores are now the share of query terms a chunk contains, already 0 to 1."
  ]

  defp warn_deprecated_opts(opts) do
    require Logger

    for {key, hint} <- @deprecated_opts, Keyword.has_key?(opts, key) do
      Logger.warning("[Arcana.VectorStore.Pgvector] :#{key} is deprecated and ignored, #{hint}")
    end

    :ok
  end

  # Prefer a pre-resolved :collection_id so the query is pinned to the ID
  # resolved by Arcana.Search. Only nil and :all are unscoped. An unknown
  # explicit name always matches nothing, including direct backend calls.
  defp resolve_filter_collection_id(collection, repo, opts) do
    case Keyword.get(opts, :collection_id) do
      nil -> resolve_filter_by_name(collection, repo, opts)
      id -> {:ok, id}
    end
  end

  defp resolve_filter_by_name(nil, _repo, _opts), do: {:ok, nil}
  defp resolve_filter_by_name(:all, _repo, _opts), do: {:ok, nil}

  defp resolve_filter_by_name(collection, repo, _opts) do
    case repo.get_by(Collection, name: collection) do
      nil -> :unknown
      coll -> {:ok, coll.id}
    end
  end

  # pgvector's own bound on hnsw.ef_search. Checked here rather than left to
  # Postgres because out of range fails two different ways: on a connection that
  # has already loaded pgvector it raises a bare Postgrex.Error, but on a fresh
  # one set_config runs before the library loads, succeeds against a placeholder
  # GUC, and is then silently reset to the default when the search query loads
  # pgvector - so the search runs at default recall, which is the under-return
  # this option exists to avoid. Nondeterministic per pooled connection.
  @ef_search_range 1..1000

  @doc false
  def ef_search!(opts) do
    case Keyword.get(opts, :hnsw_ef_search) do
      nil ->
        nil

      ef when is_integer(ef) and ef in @ef_search_range ->
        ef

      other ->
        raise ArgumentError, """
        :hnsw_ef_search must be an integer in #{inspect(@ef_search_range)}, got: #{inspect(other)}

        It is pgvector's hnsw.ef_search: how many candidates an index scan
        considers before filtering. Higher finds more of the true nearest
        neighbours on a filtered search, at the cost of more work per query.
        pgvector rejects anything outside #{inspect(@ef_search_range)}.
        """
    end
  end

  # hnsw.ef_search is a GUC, so it only applies for the duration of a
  # transaction. The transaction here is doing two jobs and neither is optional:
  # it scopes the setting, and it pins the set_config and the query to the same
  # pooled connection - without it they can land on different connections and
  # the setting silently does nothing. Do not unwrap it.
  #
  # set_config/3 rather than SET LOCAL because SET takes no bind parameters, and
  # this value reaches SQL from user options.
  #
  # Inside an enclosing transaction Ecto joins it rather than nesting, so the
  # setting persists until that transaction ends rather than just for this
  # query. pgvector's own docs describe the same caveat.
  defp with_ef_search(_repo, nil, fun), do: fun.()

  defp with_ef_search(repo, ef, fun) when is_integer(ef) and ef > 0 do
    {:ok, result} =
      repo.transaction(fn ->
        repo.query!("SELECT set_config('hnsw.ef_search', $1, true)", [Integer.to_string(ef)])
        fun.()
      end)

    result
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
