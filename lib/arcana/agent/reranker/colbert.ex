defmodule Arcana.Agent.Reranker.ColBERT do
  @moduledoc """
  ColBERT-style neural reranker using per-token embeddings and MaxSim scoring.

  Uses the Stephen library to rerank chunks with fine-grained semantic matching.
  Unlike single-vector embeddings, ColBERT maintains one embedding per token,
  enabling more nuanced relevance scoring.

  ## Requirements

  Add stephen to your dependencies:

      {:stephen, "~> 0.1"}

  ## Usage

      # With Agent pipeline
      ctx
      |> Agent.search()
      |> Agent.rerank(reranker: Arcana.Agent.Reranker.ColBERT)
      |> Agent.answer()

      # With custom encoder
      ctx
      |> Agent.search()
      |> Agent.rerank(reranker: {Arcana.Agent.Reranker.ColBERT, encoder: my_encoder})
      |> Agent.answer()

      # Directly
      {:ok, reranked} = Arcana.Agent.Reranker.ColBERT.rerank(
        "What is Elixir?",
        chunks,
        threshold: 0.5
      )

  ## Options

    * `:encoder` - Pre-loaded Stephen encoder. If not provided, loads the default
      encoder on first use (cached for subsequent calls).
    * `:threshold` - Minimum score to keep (default: 0.0). ColBERT scores are
      typically in the range 0-30+ depending on query/document length.
    * `:top_k` - Maximum number of results to return (default: all above threshold)

  ## Score Interpretation

  ColBERT scores are the sum of maximum similarities between query tokens and
  document tokens. Higher is better, but the scale depends on query length:
  - Short queries (2-3 words): scores typically 5-15
  - Medium queries (5-10 words): scores typically 10-25
  - Long queries (10+ words): scores typically 20-40+

  Consider using `:top_k` rather than `:threshold` for most use cases.
  """

  @behaviour Arcana.Agent.Reranker

  @default_threshold 0.0

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    unless Code.ensure_loaded?(Stephen) do
      raise """
      Stephen is required for ColBERT reranking but not available.

      Add it to your dependencies:

          {:stephen, "~> 0.1"}
      """
    end

    encoder = get_encoder(opts)
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    top_k = Keyword.get(opts, :top_k)

    # Build candidates as {id, text} tuples for Stephen
    candidates =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, idx} -> {to_string(idx), chunk.text} end)

    # Rerank using Stephen
    results = Stephen.rerank_texts(encoder, question, candidates)

    # Map back to chunks with scores
    chunks_by_idx =
      chunks |> Enum.with_index() |> Map.new(fn {chunk, idx} -> {to_string(idx), chunk} end)

    scored_chunks =
      results
      |> Enum.filter(fn %{score: score} -> score >= threshold end)
      |> maybe_take_top_k(top_k)
      |> Enum.map(fn %{doc_id: idx, score: score} ->
        chunk = Map.fetch!(chunks_by_idx, idx)
        Map.put(chunk, :rerank_score, score)
      end)

    {:ok, scored_chunks}
  end

  defp get_encoder(opts) do
    case Keyword.get(opts, :encoder) do
      nil -> get_or_load_default_encoder()
      encoder -> encoder
    end
  end

  defp get_or_load_default_encoder do
    case :persistent_term.get({__MODULE__, :encoder}, nil) do
      nil ->
        {:ok, encoder} = Stephen.load_encoder()
        :persistent_term.put({__MODULE__, :encoder}, encoder)
        encoder

      encoder ->
        encoder
    end
  end

  defp maybe_take_top_k(results, nil), do: results
  defp maybe_take_top_k(results, k), do: Enum.take(results, k)
end
