defmodule Arcana.SearchResult do
  @moduledoc """
  Normalized search result returned by `Arcana.search/2` for every mode.

  All modes (`:vector`, `:keyword`, `:hybrid`, and graph-enhanced search)
  return the same struct, so integrators never need per-mode formatters.

  ## Fields

    * `:id` - Chunk id (UUID string)
    * `:text` - Chunk text
    * `:document_id` - Owning document id (UUID string)
    * `:chunk_index` - Position of the chunk within its document
    * `:score` - Final relevance score for the mode that produced it
    * `:vector_score` - Vector similarity component. Only set by the
      single-query hybrid search on the pgvector backend, `nil` elsewhere.
    * `:keyword_score` - Keyword relevance component. Same availability
      as `:vector_score`.
    * `:rerank_score` - Score attached by rerankers that produce one
      (e.g. `Arcana.Reranker.ColBERT`), `nil` otherwise.
    * `:metadata` - The chunk's stored metadata with string keys.

  The struct implements the `Access` behaviour for reads, so `result[:text]`
  keeps working for code that used the previous plain maps.

  ## Serializing

  Use `to_map/1`:

      results |> Enum.map(&Arcana.SearchResult.to_map/1) |> JSON.encode!()

  The struct is deliberately not derived for `Jason.Encoder` or
  `JSON.Encoder`. Deriving would make the field set part of the wire
  contract, so adding or renaming a field would break everyone serializing
  results. `to_map/1` is the seam instead: it returns a shape this module
  commits to, and lets fields be added without exposing them.

  Two things not to do. `Map.from_struct/1` works today but makes the
  private field set your contract, so a field added later that isn't
  JSON-safe breaks you at encode time. And a `defimpl JSON.Encoder, for:
  Arcana.SearchResult` in your own application is an orphan implementation
  for a struct you don't own: it collides if Arcana ever ships one, and with
  any other library that did the same.
  """

  @behaviour Access

  defstruct [
    :id,
    :text,
    :document_id,
    :chunk_index,
    :score,
    :vector_score,
    :keyword_score,
    :rerank_score,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | term(),
          text: String.t(),
          document_id: String.t() | nil,
          chunk_index: non_neg_integer() | nil,
          score: number(),
          vector_score: number() | nil,
          keyword_score: number() | nil,
          rerank_score: number() | nil,
          metadata: map()
        }

  @doc """
  The result as a plain map, for encoding, logging, or handing to a model.

  Fields are listed explicitly rather than taken from the struct, so this
  stays a contract: a field added to the struct later is not silently
  exposed to everything that serializes a result, and the keys here can
  outlive an internal rename.

      iex> result = %Arcana.SearchResult{id: "abc", text: "hello", score: 0.9}
      iex> map = Arcana.SearchResult.to_map(result)
      iex> {map.id, map.text, map.score, map.metadata}
      {"abc", "hello", 0.9, %{}}

  `:metadata` is passed through as stored, with string keys.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      id: result.id,
      text: result.text,
      document_id: result.document_id,
      chunk_index: result.chunk_index,
      score: result.score,
      vector_score: result.vector_score,
      keyword_score: result.keyword_score,
      rerank_score: result.rerank_score,
      metadata: result.metadata
    }
  end

  @known_keys [:text, :chunk_index, :document_id, :vector_score, :keyword_score]

  @doc """
  Builds a result from a vector-store backend map (`%{id, score, metadata}`).

  Backend metadata mixes the chunk's stored metadata with well-known keys
  (`:text`, `:chunk_index`, `:document_id`, and hybrid score components);
  the well-known keys become struct fields and the rest is kept under
  `:metadata` with keys normalized to strings.
  """
  def from_store_result(%{id: id, score: score} = result) do
    metadata = Map.get(result, :metadata) || %{}

    %__MODULE__{
      id: id,
      text: known(metadata, :text) || "",
      document_id: known(metadata, :document_id),
      chunk_index: known(metadata, :chunk_index),
      score: score,
      vector_score: known(metadata, :vector_score),
      keyword_score: known(metadata, :keyword_score),
      metadata: user_metadata(metadata)
    }
  end

  # Backend metadata may carry well-known keys as atoms (Ecto select
  # merge) or strings (JSONB round-trips, custom backends): accept both.
  defp known(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp user_metadata(metadata) do
    metadata
    |> Map.drop(@known_keys)
    |> Map.drop(Enum.map(@known_keys, &Atom.to_string/1))
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  @impl Access
  def fetch(%__MODULE__{} = result, key) when is_atom(key), do: Map.fetch(result, key)
  def fetch(%__MODULE__{}, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = result, key, fun)
      when is_map_key(result, key) and key != :__struct__ do
    current = Map.get(result, key)

    case fun.(current) do
      {get, update} -> {get, Map.replace!(result, key, update)}
      :pop -> pop(result, key)
    end
  end

  def get_and_update(%__MODULE__{}, key, _fun) do
    raise ArgumentError,
          "Arcana.SearchResult only supports Access updates on its own fields, " <>
            "got: #{inspect(key)}"
  end

  @impl Access
  def pop(%__MODULE__{} = result, :metadata), do: {result.metadata, %{result | metadata: %{}}}

  def pop(%__MODULE__{} = result, key) when is_map_key(result, key) and key != :__struct__ do
    {Map.get(result, key), Map.replace!(result, key, nil)}
  end

  def pop(%__MODULE__{}, key) do
    raise ArgumentError,
          "Arcana.SearchResult only supports Access updates on its own fields, " <>
            "got: #{inspect(key)}"
  end
end
