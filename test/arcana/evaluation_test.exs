defmodule Arcana.EvaluationTest do
  use Arcana.DataCase, async: true

  alias Arcana.Evaluation
  alias Arcana.Evaluation.TestCase

  describe "generate_test_cases/1" do
    test "generates test cases from chunks using LLM" do
      # Ingest some documents
      {:ok, _doc} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
      {:ok, _doc} = Arcana.ingest("GenServers handle state in Elixir.", repo: Repo)

      # Mock LLM that generates questions
      llm = fn prompt, _context ->
        if prompt =~ "Elixir" do
          {:ok, "What programming paradigm does Elixir use?"}
        else
          {:ok, "How do you manage state in Elixir?"}
        end
      end

      {:ok, test_cases} =
        Evaluation.generate_test_cases(
          repo: Repo,
          llm: llm,
          sample_size: 2
        )

      assert length(test_cases) == 2
      assert Enum.all?(test_cases, &(&1.source == :synthetic))
      assert Enum.all?(test_cases, &(length(&1.relevant_chunks) == 1))
    end
  end

  describe "run/1" do
    setup do
      # Ingest documents
      {:ok, doc1} = Arcana.ingest("Elixir is a functional programming language.", repo: Repo)
      {:ok, doc2} = Arcana.ingest("Python is great for machine learning.", repo: Repo)

      # Get the chunks
      chunks = Repo.all(Arcana.Chunk)
      elixir_chunk = Enum.find(chunks, &(&1.document_id == doc1.id))
      python_chunk = Enum.find(chunks, &(&1.document_id == doc2.id))

      # Create test cases manually
      {:ok, tc1} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "What is Elixir?",
          relevant_chunk_ids: [elixir_chunk.id]
        )

      {:ok, tc2} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "What is Python used for?",
          relevant_chunk_ids: [python_chunk.id]
        )

      %{test_cases: [tc1, tc2], chunks: %{elixir: elixir_chunk, python: python_chunk}}
    end

    test "runs evaluation and computes metrics", %{test_cases: test_cases} do
      {:ok, run} = Evaluation.run(repo: Repo, mode: :semantic)

      assert run.status == :completed
      assert run.test_case_count == 2
      assert run.config.mode == :semantic

      # Check metrics exist
      assert is_float(run.metrics.recall_at_5)
      assert is_float(run.metrics.precision_at_5)
      assert is_float(run.metrics.mrr)

      # Check per-case results exist
      assert map_size(run.results) == 2

      for tc <- test_cases do
        assert Map.has_key?(run.results, tc.id)
      end
    end

    test "returns error when no test cases exist" do
      # Clear test cases
      Repo.delete_all(TestCase)

      assert {:error, :no_test_cases} = Evaluation.run(repo: Repo)
    end
  end

  describe "list_test_cases/1" do
    test "returns all test cases" do
      {:ok, _doc} = Arcana.ingest("Test content", repo: Repo)
      chunk = Repo.one(Arcana.Chunk)

      {:ok, _tc} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "Test question?",
          relevant_chunk_ids: [chunk.id]
        )

      test_cases = Evaluation.list_test_cases(repo: Repo)

      assert length(test_cases) == 1
      assert hd(test_cases).question == "Test question?"
    end
  end

  describe "create_test_case/1" do
    test "creates manual test case with relevant chunks" do
      {:ok, _doc} = Arcana.ingest("Test content", repo: Repo)
      chunk = Repo.one(Arcana.Chunk)

      {:ok, test_case} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "What is the test about?",
          relevant_chunk_ids: [chunk.id]
        )

      assert test_case.question == "What is the test about?"
      assert test_case.source == :manual
      assert length(test_case.relevant_chunks) == 1
      assert hd(test_case.relevant_chunks).id == chunk.id
    end
  end

  describe "delete_test_case/2" do
    test "deletes an existing test case" do
      {:ok, _doc} = Arcana.ingest("Test content", repo: Repo)
      chunk = Repo.one(Arcana.Chunk)

      {:ok, test_case} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "Test?",
          relevant_chunk_ids: [chunk.id]
        )

      {:ok, _deleted} = Evaluation.delete_test_case(test_case.id, repo: Repo)

      assert Evaluation.get_test_case(test_case.id, repo: Repo) == nil
    end

    test "returns error for non-existent test case" do
      assert {:error, :not_found} =
               Evaluation.delete_test_case(Ecto.UUID.generate(), repo: Repo)
    end
  end

  describe "list_runs/1" do
    test "returns evaluation runs ordered by date" do
      {:ok, _doc} = Arcana.ingest("Test content", repo: Repo)
      chunk = Repo.one(Arcana.Chunk)

      {:ok, _tc} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "Test?",
          relevant_chunk_ids: [chunk.id]
        )

      {:ok, _run1} = Evaluation.run(repo: Repo)
      {:ok, run2} = Evaluation.run(repo: Repo)

      runs = Evaluation.list_runs(repo: Repo)

      assert length(runs) == 2
      assert hd(runs).id == run2.id
    end
  end

  describe "delete_run/2" do
    test "deletes an evaluation run" do
      {:ok, _doc} = Arcana.ingest("Test content", repo: Repo)
      chunk = Repo.one(Arcana.Chunk)

      {:ok, _tc} =
        Evaluation.create_test_case(
          repo: Repo,
          question: "Test?",
          relevant_chunk_ids: [chunk.id]
        )

      {:ok, run} = Evaluation.run(repo: Repo)
      {:ok, _deleted} = Evaluation.delete_run(run.id, repo: Repo)

      assert Evaluation.get_run(run.id, repo: Repo) == nil
    end
  end
end
