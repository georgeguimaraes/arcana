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
  keeps working for code that used the previous plain maps. It is not
  derived for `Jason.Encoder` or `JSON.Encoder`; encode `Map.from_struct/1`
  if you need JSON.
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
      text: metadata[:text] || "",
      document_id: metadata[:document_id],
      chunk_index: metadata[:chunk_index],
      score: score,
      vector_score: metadata[:vector_score],
      keyword_score: metadata[:keyword_score],
      metadata: user_metadata(metadata)
    }
  end

  defp user_metadata(metadata) do
    metadata
    |> Map.drop(@known_keys)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  @impl Access
  def fetch(%__MODULE__{} = result, key) when is_atom(key), do: Map.fetch(result, key)
  def fetch(%__MODULE__{}, _key), do: :error

  @impl Access
  def get_and_update(%__MODULE__{} = result, key, fun) when is_map_key(result, key) do
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

  def pop(%__MODULE__{} = result, key) when is_map_key(result, key) do
    {Map.get(result, key), Map.replace!(result, key, nil)}
  end

  def pop(%__MODULE__{}, key) do
    raise ArgumentError,
          "Arcana.SearchResult only supports Access updates on its own fields, " <>
            "got: #{inspect(key)}"
  end
end
