defmodule Arcana.Evaluation.Metrics do
  @moduledoc """
  Computes retrieval evaluation metrics.

  Supports Recall@K, Precision@K, MRR (Mean Reciprocal Rank),
  and Hit Rate@K for standard K values [1, 3, 5, 10].
  """

  @k_values [1, 3, 5, 10]

  @doc """
  Returns the K values used for evaluation.
  """
  def k_values, do: @k_values

  @doc """
  Evaluates a single test case against search results.

  Returns a map with per-K metrics and debugging info.
  """
  def evaluate_case(test_case, search_results) do
    retrieved_ids = Enum.map(search_results, & &1.id)
    expected_ids = test_case.relevant_chunks |> Enum.map(& &1.id) |> MapSet.new()

    %{
      test_case_id: test_case.id,
      question: test_case.question,
      expected_chunk_ids: MapSet.to_list(expected_ids),
      retrieved_chunk_ids: retrieved_ids,
      recall: recall_at_k(retrieved_ids, expected_ids),
      precision: precision_at_k(retrieved_ids, expected_ids),
      reciprocal_rank: reciprocal_rank(retrieved_ids, expected_ids),
      hit: hit_at_k(retrieved_ids, expected_ids)
    }
  end

  @doc """
  Aggregates per-case results into summary metrics.
  """
  def aggregate(case_results) when is_list(case_results) do
    n = length(case_results)

    if n == 0 do
      empty_metrics()
    else
      %{
        recall_at_1: avg(case_results, [:recall, 1]),
        recall_at_3: avg(case_results, [:recall, 3]),
        recall_at_5: avg(case_results, [:recall, 5]),
        recall_at_10: avg(case_results, [:recall, 10]),
        precision_at_1: avg(case_results, [:precision, 1]),
        precision_at_3: avg(case_results, [:precision, 3]),
        precision_at_5: avg(case_results, [:precision, 5]),
        precision_at_10: avg(case_results, [:precision, 10]),
        mrr: avg_field(case_results, :reciprocal_rank),
        hit_rate_at_1: hit_rate(case_results, 1),
        hit_rate_at_3: hit_rate(case_results, 3),
        hit_rate_at_5: hit_rate(case_results, 5),
        hit_rate_at_10: hit_rate(case_results, 10),
        test_case_count: n
      }
    end
  end

  defp empty_metrics do
    %{
      recall_at_1: 0.0,
      recall_at_3: 0.0,
      recall_at_5: 0.0,
      recall_at_10: 0.0,
      precision_at_1: 0.0,
      precision_at_3: 0.0,
      precision_at_5: 0.0,
      precision_at_10: 0.0,
      mrr: 0.0,
      hit_rate_at_1: 0.0,
      hit_rate_at_3: 0.0,
      hit_rate_at_5: 0.0,
      hit_rate_at_10: 0.0,
      test_case_count: 0
    }
  end

  # Recall@K: what fraction of relevant docs appear in top K?
  defp recall_at_k(retrieved, expected) do
    expected_size = MapSet.size(expected)

    Map.new(@k_values, fn k ->
      top_k = retrieved |> Enum.take(k) |> MapSet.new()
      hits = MapSet.intersection(top_k, expected) |> MapSet.size()
      {k, if(expected_size > 0, do: hits / expected_size, else: 0.0)}
    end)
  end

  # Precision@K: what fraction of top K are relevant?
  defp precision_at_k(retrieved, expected) do
    Map.new(@k_values, fn k ->
      top_k = Enum.take(retrieved, k)
      hits = Enum.count(top_k, &MapSet.member?(expected, &1))
      {k, hits / k}
    end)
  end

  # Reciprocal Rank: 1/position of first relevant result
  defp reciprocal_rank(retrieved, expected) do
    case Enum.find_index(retrieved, &MapSet.member?(expected, &1)) do
      nil -> 0.0
      idx -> 1.0 / (idx + 1)
    end
  end

  # Hit@K: did we find at least one relevant doc in top K?
  defp hit_at_k(retrieved, expected) do
    Map.new(@k_values, fn k ->
      top_k = retrieved |> Enum.take(k) |> MapSet.new()
      has_hit = MapSet.intersection(top_k, expected) |> MapSet.size() > 0
      {k, has_hit}
    end)
  end

  defp avg(results, path) do
    values = Enum.map(results, &get_in(&1, path))
    Enum.sum(values) / length(values)
  end

  defp avg_field(results, field) do
    values = Enum.map(results, &Map.get(&1, field))
    Enum.sum(values) / length(values)
  end

  defp hit_rate(results, k) do
    hits = Enum.count(results, &get_in(&1, [:hit, k]))
    hits / length(results)
  end
end
