# Search Algorithms

Arcana supports three search modes across two vector store backends. This guide explains how each algorithm works under the hood.

## Search Modes Overview

| Mode | Purpose | Memory Backend | PgVector Backend |
|------|---------|----------------|------------------|
| `:semantic` | Find similar meaning | HNSWLib cosine similarity | pgvector HNSW index |
| `:fulltext` | Find keyword matches | TF-IDF-like scoring | PostgreSQL tsvector |
| `:hybrid` | Combine both | Two queries + RRF | Single-query with weights |

## Semantic Search

Both backends use cosine similarity to find semantically similar content.

### Memory Backend (HNSWLib)

Uses [Hierarchical Navigable Small World](https://arxiv.org/abs/1603.09320) graphs for approximate nearest neighbor search.

```
Query embedding → HNSWLib.Index.knn_query → Top-k neighbors by cosine distance
```

**Score calculation:**
```elixir
score = 1.0 - cosine_distance
```

Where `cosine_distance = 1 - cosine_similarity`. A score of 1.0 means identical vectors.

**Complexity:** O(log n) average case for k-NN queries.

### PgVector Backend

Uses PostgreSQL's pgvector extension with HNSW indexing.

```sql
SELECT *, 1 - (embedding <=> query_embedding) AS score
FROM arcana_chunks
ORDER BY embedding <=> query_embedding
LIMIT 10
```

The `<=>` operator computes cosine distance. The HNSW index makes this efficient even for millions of vectors.

## Fulltext Search

### Memory Backend: TF-IDF-like Scoring

A simplified term-matching algorithm inspired by TF-IDF:

```elixir
def calculate_text_score(query_terms, document_text) do
  doc_terms = tokenize(document_text)
  matching = count_matching_terms(query_terms, doc_terms)

  # What fraction of query terms appear in the document
  term_ratio = matching / length(query_terms)

  # Penalize long documents (they match more by chance)
  length_factor = 1.0 / :math.log(length(doc_terms) + 1)

  term_ratio * length_factor
end
```

**Example:**

Query: `"elixir pattern matching"` (3 terms)

| Document | Matches | Term Ratio | Length | Length Factor | Score |
|----------|---------|------------|--------|---------------|-------|
| "Pattern matching in Elixir is powerful" | 3 | 1.0 | 6 | 0.51 | 0.51 |
| "Elixir is great" | 1 | 0.33 | 3 | 0.72 | 0.24 |
| "A very long document about many topics including elixir..." | 1 | 0.33 | 50 | 0.26 | 0.09 |

**Why "TF-IDF-like" not actual TF-IDF:**

| Feature | Real TF-IDF | Memory Backend |
|---------|-------------|----------------|
| Term frequency | Counts occurrences | Binary (present/absent) |
| Inverse document frequency | Corpus-wide statistics | No corpus index |
| Document length normalization | Yes | Yes (via log factor) |

The simplification avoids maintaining a persistent term index, which would add complexity to an in-memory store.

### PgVector Backend: PostgreSQL Full-Text Search

Uses PostgreSQL's battle-tested full-text search with `tsvector` and `tsquery`:

```sql
SELECT *,
  ts_rank(to_tsvector('english', text), to_tsquery('english', 'elixir & pattern & matching')) AS score
FROM arcana_chunks
WHERE to_tsvector('english', text) @@ to_tsquery('english', 'elixir & pattern & matching')
ORDER BY score DESC
```

**How it works:**

1. **`to_tsvector`**: Converts text to a searchable vector of lexemes (normalized word forms)
   - "running" → "run"
   - "patterns" → "pattern"
   - Removes stop words ("the", "is", "a")

2. **`to_tsquery`**: Converts query to search terms joined with `&` (AND)
   - `"elixir pattern matching"` → `'elixir' & 'pattern' & 'match'`

3. **`@@` operator**: Returns true if document matches query

4. **`ts_rank`**: Scores documents by:
   - Term frequency in document
   - Inverse document frequency (rarity)
   - Term proximity (how close terms appear)

**Advantages over Memory backend:**
- Stemming (matches "running" when searching "run")
- Stop word removal
- Proximity scoring
- Language-aware processing

## Hybrid Search

Hybrid mode combines semantic and fulltext search. The implementation differs by backend:

| Backend | Approach | Advantages |
|---------|----------|------------|
| PgVector | Single-query weighted combination | Better coverage, configurable weights |
| Memory | Two queries + RRF | Simple, rank-based fusion |

### PgVector Backend: Single-Query Hybrid

The pgvector backend uses a single SQL query that combines both scores:

```sql
WITH base_scores AS (
  SELECT
    id, text, embedding,
    1 - (embedding <=> query_embedding) AS semantic_score,
    ts_rank(to_tsvector('english', text), query) AS fulltext_score
  FROM arcana_chunks
),
normalized AS (
  SELECT *,
    (fulltext_score - MIN(fulltext_score) OVER ()) /
    NULLIF(MAX(fulltext_score) OVER () - MIN(fulltext_score) OVER (), 0)
    AS fulltext_normalized
  FROM base_scores
)
SELECT *,
  (semantic_weight * semantic_score + fulltext_weight * fulltext_normalized) AS hybrid_score
FROM normalized
ORDER BY hybrid_score DESC
```

**Why single-query is better:**

With separate queries, items ranking moderately in both lists might be missed. For example:
- Semantic search fetches top 20
- Fulltext search fetches top 20
- An item ranking #15 in both could be highly relevant overall, but RRF only sees it at position 15

Single-query evaluates **all** chunks, ensuring nothing is missed.

**Score normalization:**
- Semantic scores (cosine similarity) naturally range 0-1
- Fulltext scores (ts_rank) vary widely based on document content
- The query normalizes fulltext scores using min-max scaling within the result set

**Configurable weights:**

```elixir
# Equal weight (default)
{:ok, results} = Arcana.search("query", repo: Repo, mode: :hybrid)

# Favor semantic similarity
{:ok, results} = Arcana.search("query", repo: Repo, mode: :hybrid, semantic_weight: 0.7, fulltext_weight: 0.3)

# Favor keyword matches
{:ok, results} = Arcana.search("query", repo: Repo, mode: :hybrid, semantic_weight: 0.3, fulltext_weight: 0.7)
```

Results include individual scores for debugging:

```elixir
%{
  id: "...",
  text: "...",
  score: 0.75,           # Combined hybrid score
  semantic_score: 0.82,  # Cosine similarity
  fulltext_score: 0.68   # Raw ts_rank score
}
```

### Memory Backend: Reciprocal Rank Fusion (RRF)

For the memory backend (and other custom backends), hybrid search uses [Reciprocal Rank Fusion](https://plg.uwaterloo.ca/~gvcormac/cormacksigir09-rrf.pdf) to combine results from separate queries.

**The Problem:**

Semantic and fulltext searches return scores on different scales:
- Semantic: 0.0 to 1.0 (cosine similarity)
- Fulltext: Unbounded (ts_rank or term matching)

Naively averaging scores would bias toward one method.

**The Solution: RRF**

RRF scores by **rank position**, not raw score:

```elixir
def rrf_score(rank, k \\ 60) do
  1.0 / (k + rank)
end
```

Where `k` is a constant (default 60) that prevents top-ranked items from dominating.

**Algorithm:**

```elixir
def rrf_combine(semantic_results, fulltext_results, limit) do
  # Build rank maps
  semantic_ranks = build_rank_map(semantic_results)
  fulltext_ranks = build_rank_map(fulltext_results)

  # Combine all unique IDs
  all_ids = MapSet.union(Map.keys(semantic_ranks), Map.keys(fulltext_ranks))

  # Calculate RRF score for each
  all_ids
  |> Enum.map(fn id ->
    semantic_rank = Map.get(semantic_ranks, id, 1000)  # Default: low rank
    fulltext_rank = Map.get(fulltext_ranks, id, 1000)

    rrf_score = 1/(60 + semantic_rank) + 1/(60 + fulltext_rank)
    {id, rrf_score}
  end)
  |> Enum.sort_by(&elem(&1, 1), :desc)
  |> Enum.take(limit)
end
```

**Example:**

Query: `"BEAM virtual machine"`

| Document | Semantic Rank | Fulltext Rank | Semantic RRF | Fulltext RRF | Combined |
|----------|---------------|---------------|--------------|--------------|----------|
| "Erlang runs on the BEAM VM" | 1 | 2 | 0.016 | 0.016 | 0.032 |
| "The BEAM virtual machine" | - | 1 | 0.001 | 0.016 | 0.017 |
| "The BEAM is Erlang's runtime" | 2 | - | 0.016 | 0.001 | 0.017 |

Documents appearing in **both** result sets get boosted to the top.

## Choosing the Right Mode

| Use Case | Recommended Mode |
|----------|------------------|
| Conceptual questions ("How does X work?") | `:semantic` |
| Exact terms, names, codes | `:fulltext` |
| General search, unknown query type | `:hybrid` |
| API/function lookup | `:fulltext` |
| Finding related concepts | `:semantic` |

## Backend Comparison

| Aspect | Memory | PgVector |
|--------|--------|----------|
| Setup | No database needed | Requires PostgreSQL + pgvector |
| Persistence | Lost on restart | Persisted |
| Semantic search | HNSWLib (excellent) | pgvector HNSW (excellent) |
| Fulltext search | Basic term matching | Full linguistic processing |
| Stemming | No | Yes |
| Stop words | No | Yes |
| Scale | < 100K vectors | Millions of vectors |
| Best for | Testing, small apps | Production |
