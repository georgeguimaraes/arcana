defmodule Arcana.Evaluation.MetricsTest do
  use ExUnit.Case, async: true

  alias Arcana.Evaluation.Metrics

  describe "k_values/0" do
    test "returns standard K values" do
      assert Metrics.k_values() == [1, 3, 5, 10]
    end
  end

  describe "evaluate_case/2" do
    test "computes metrics for perfect retrieval" do
      test_case = %{
        id: "tc-1",
        question: "What is Elixir?",
        relevant_chunks: [%{id: "chunk-1"}, %{id: "chunk-2"}]
      }

      search_results = [
        %{id: "chunk-1"},
        %{id: "chunk-2"},
        %{id: "chunk-3"}
      ]

      result = Metrics.evaluate_case(test_case, search_results)

      assert result.recall[1] == 0.5
      assert result.recall[3] == 1.0
      assert result.precision[1] == 1.0
      assert result.precision[3] == 2 / 3
      assert result.reciprocal_rank == 1.0
      assert result.hit[1] == true
    end

    test "computes metrics when first result is not relevant" do
      test_case = %{
        id: "tc-1",
        question: "What is Elixir?",
        relevant_chunks: [%{id: "chunk-2"}]
      }

      search_results = [
        %{id: "chunk-1"},
        %{id: "chunk-2"},
        %{id: "chunk-3"}
      ]

      result = Metrics.evaluate_case(test_case, search_results)

      assert result.recall[1] == 0.0
      assert result.recall[3] == 1.0
      assert result.precision[1] == 0.0
      assert result.reciprocal_rank == 0.5
      assert result.hit[1] == false
      assert result.hit[3] == true
    end

    test "handles no relevant results found" do
      test_case = %{
        id: "tc-1",
        question: "What is Elixir?",
        relevant_chunks: [%{id: "chunk-99"}]
      }

      search_results = [
        %{id: "chunk-1"},
        %{id: "chunk-2"},
        %{id: "chunk-3"}
      ]

      result = Metrics.evaluate_case(test_case, search_results)

      assert result.recall[1] == 0.0
      assert result.recall[10] == 0.0
      assert result.reciprocal_rank == 0.0
      assert result.hit[10] == false
    end
  end

  describe "aggregate/1" do
    test "computes average metrics across cases" do
      case_results = [
        %{
          recall: %{1 => 1.0, 3 => 1.0, 5 => 1.0, 10 => 1.0},
          precision: %{1 => 1.0, 3 => 0.33, 5 => 0.2, 10 => 0.1},
          reciprocal_rank: 1.0,
          hit: %{1 => true, 3 => true, 5 => true, 10 => true}
        },
        %{
          recall: %{1 => 0.0, 3 => 1.0, 5 => 1.0, 10 => 1.0},
          precision: %{1 => 0.0, 3 => 0.33, 5 => 0.2, 10 => 0.1},
          reciprocal_rank: 0.5,
          hit: %{1 => false, 3 => true, 5 => true, 10 => true}
        }
      ]

      metrics = Metrics.aggregate(case_results)

      assert metrics.recall_at_1 == 0.5
      assert metrics.recall_at_3 == 1.0
      assert metrics.mrr == 0.75
      assert metrics.hit_rate_at_1 == 0.5
      assert metrics.hit_rate_at_3 == 1.0
      assert metrics.test_case_count == 2
    end

    test "returns zeros for empty results" do
      metrics = Metrics.aggregate([])

      assert metrics.recall_at_5 == 0.0
      assert metrics.mrr == 0.0
      assert metrics.test_case_count == 0
    end
  end
end
