defmodule Arcana.Evaluation do
  @moduledoc """
  Retrieval evaluation for measuring search quality.

  Generates synthetic test cases from your document chunks and
  evaluates retrieval performance with standard IR metrics.

  ## Usage

      # Generate test cases from chunks
      {:ok, test_cases} = Arcana.Evaluation.generate_test_cases(
        repo: MyApp.Repo,
        llm: my_llm,
        sample_size: 50
      )

      # Run evaluation
      {:ok, run} = Arcana.Evaluation.run(repo: MyApp.Repo, mode: :vector)

      # View metrics
      run.metrics
      # => %{recall_at_5: 0.84, precision_at_5: 0.68, mrr: 0.76, ...}

  """

  import Ecto.Query

  alias Arcana.Evaluation.{Generator, Metrics, Run, TestCase}

  @doc """
  Generates synthetic test cases from existing chunks.

  Samples chunks randomly and uses an LLM to generate questions
  that should retrieve those chunks.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:llm` - LLM implementing Arcana.LLM protocol (required)
    * `:sample_size` - Number of chunks to sample (default: 50)
    * `:source_id` - Limit to chunks from specific source
    * `:prompt` - Custom prompt template

  """
  def generate_test_cases(opts) do
    Generator.generate(opts)
  end

  @doc """
  Runs evaluation against existing test cases.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:mode` - Search mode `:vector | :keyword | :hybrid` (default: `:vector`).
      `:semantic` and `:fulltext` are deprecated aliases and log a warning.
    * `:source_id` - Limit evaluation to specific source
    * `:evaluate_answers` - When true, also evaluates answer quality (default: false)
    * `:llm` - LLM function (required when evaluate_answers is true)
    * `:retriever` - Custom retriever function `(question, opts) -> {:ok, chunks}`.
      Defaults to `Arcana.search/2`. Use this to evaluate alternative retrieval
      strategies (e.g., `Arcana.Loop`) against the same test set with the
      same metrics. The chunks returned must be maps with `:id` so the
      metrics can match them against the test case's `relevant_chunks`.

  """
  def run(opts) do
    repo = Keyword.fetch!(opts, :repo)
    mode = Arcana.Search.normalize_mode(Keyword.get(opts, :mode, :vector))
    source_id = Keyword.get(opts, :source_id)
    evaluate_answers = Keyword.get(opts, :evaluate_answers, false)
    llm = Keyword.get(opts, :llm)
    retriever = Keyword.get(opts, :retriever, &default_retriever/2)

    # Validate llm is provided when evaluate_answers is true
    if evaluate_answers and is_nil(llm) do
      raise ArgumentError, ":llm is required when evaluate_answers: true"
    end

    test_cases = list_test_cases(opts)

    if Enum.empty?(test_cases) do
      {:error, :no_test_cases}
    else
      # Build config with full Arcana settings
      arcana_config = Arcana.config()

      run_config =
        arcana_config
        |> Map.put(:mode, mode)
        |> Map.put(:source_id, source_id)
        |> Map.put(:evaluate_answers, evaluate_answers)

      # Create a run record
      {:ok, run} =
        %Run{}
        |> Run.changeset(%{
          status: :running,
          config: run_config,
          test_case_count: length(test_cases)
        })
        |> repo.insert()

      total = length(test_cases)

      :telemetry.execute(
        [:arcana, :evaluation, :start],
        %{total: total},
        %{run_id: run.id}
      )

      # Evaluate each test case, emitting per-case telemetry so dashboards
      # can render live progress on long runs (Loop + evaluate_answers
      # against 10+ test cases can take 20 minutes with a chat-tier LLM).
      case_results =
        test_cases
        |> Enum.with_index(1)
        |> Enum.map(fn {test_case, index} ->
          :telemetry.execute(
            [:arcana, :evaluation, :test_case, :start],
            %{index: index},
            %{
              run_id: run.id,
              index: index,
              total: total,
              question: test_case.question
            }
          )

          started_at = System.monotonic_time()

          result =
            evaluate_test_case(test_case, repo, mode, evaluate_answers, llm, retriever)

          duration_ms =
            System.convert_time_unit(
              System.monotonic_time() - started_at,
              :native,
              :millisecond
            )

          :telemetry.execute(
            [:arcana, :evaluation, :test_case, :complete],
            %{duration_ms: duration_ms, index: index},
            %{
              run_id: run.id,
              index: index,
              total: total,
              question: test_case.question
            }
          )

          result
        end)

      # Aggregate metrics
      metrics = Metrics.aggregate(case_results)

      # Add answer metrics if evaluated
      metrics =
        if evaluate_answers do
          metrics
          |> maybe_put_faithfulness(case_results)
          |> maybe_put_correctness(case_results)
        else
          metrics
        end

      # Convert case results to storable format
      results_map =
        case_results
        |> Enum.map(fn r -> {r.test_case_id, r} end)
        |> Map.new()

      # Update run with results
      {:ok, run} =
        run
        |> Run.changeset(%{
          status: :completed,
          metrics: metrics,
          results: results_map
        })
        |> repo.update()

      {:ok, run}
    end
  end

  defp evaluate_test_case(test_case, repo, mode, evaluate_answers, llm, retriever) do
    {search_results, pre_generated_answer} =
      case retriever.(test_case.question, repo: repo, mode: mode, limit: 10) do
        {:ok, chunks} -> {chunks, nil}
        {:ok, chunks, answer} -> {chunks, answer}
        # A failing retriever (e.g. Arcana.search/2 returning {:error, _})
        # used to crash the whole run with a CaseClauseError. Treat it as
        # a miss for this test case so the rest of the run still completes.
        {:error, _reason} -> {[], nil}
      end

    retrieval_metrics = Metrics.evaluate_case(test_case, search_results)

    if evaluate_answers do
      answer_metrics =
        evaluate_answer(
          test_case.question,
          search_results,
          pre_generated_answer,
          test_case.reference_answer,
          llm
        )

      Map.merge(retrieval_metrics, answer_metrics)
    else
      retrieval_metrics
    end
  end

  defp default_retriever(question, opts) do
    Arcana.search(question, opts)
  end

  defp average_faithfulness(case_results) do
    scores =
      case_results
      |> Enum.map(& &1.faithfulness_score)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(scores), do: nil, else: Enum.sum(scores) / length(scores)
  end

  defp average_correctness(case_results) do
    scores =
      case_results
      |> Enum.map(&Map.get(&1, :correctness_score))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(scores), do: nil, else: Enum.sum(scores) / length(scores)
  end

  defp maybe_put_faithfulness(metrics, case_results) do
    case average_faithfulness(case_results) do
      nil -> metrics
      avg -> Map.put(metrics, :faithfulness, avg)
    end
  end

  defp maybe_put_correctness(metrics, case_results) do
    case average_correctness(case_results) do
      nil -> metrics
      avg -> Map.put(metrics, :correctness, avg)
    end
  end

  defp evaluate_answer(question, search_results, pre_generated, reference_answer, llm) do
    answer = pre_generated || generate_answer(question, search_results, llm)

    faithfulness = score_faithfulness(question, search_results, answer, llm)
    correctness = score_correctness(question, answer, reference_answer, llm)

    Map.merge(faithfulness, correctness)
  end

  defp generate_answer(question, search_results, llm) do
    chunks_text = Enum.map_join(search_results, "\n\n", & &1.text)

    answer_prompt = """
    Answer the following question based only on the provided context.

    Context:
    #{chunks_text}

    Question: #{question}

    Answer:
    """

    case Arcana.LLM.complete(llm, answer_prompt, [], []) do
      {:ok, response} -> response
      {:error, _} -> nil
    end
  end

  defp score_faithfulness(_question, _chunks, nil, _llm) do
    %{answer: nil, faithfulness_score: nil, faithfulness_reasoning: nil}
  end

  defp score_faithfulness(question, chunks, answer, llm) do
    alias Arcana.Evaluation.AnswerMetrics

    case AnswerMetrics.evaluate_faithfulness(question, chunks, answer, llm: llm) do
      {:ok, %{score: score, reasoning: reasoning}} ->
        %{
          answer: answer,
          faithfulness_score: score,
          faithfulness_reasoning: reasoning
        }

      {:error, _} ->
        %{answer: answer, faithfulness_score: nil, faithfulness_reasoning: nil}
    end
  end

  defp score_correctness(_question, _answer, nil, _llm) do
    %{correctness_score: nil, correctness_reasoning: nil}
  end

  defp score_correctness(_question, nil, _reference, _llm) do
    %{correctness_score: nil, correctness_reasoning: nil}
  end

  defp score_correctness(question, answer, reference_answer, llm) do
    alias Arcana.Evaluation.AnswerMetrics

    case AnswerMetrics.evaluate_correctness(question, answer, reference_answer, llm: llm) do
      {:ok, %{score: score, reasoning: reasoning}} ->
        %{correctness_score: score, correctness_reasoning: reasoning}

      {:error, _} ->
        %{correctness_score: nil, correctness_reasoning: nil}
    end
  end

  @doc """
  Lists all test cases.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:source_id` - Filter by source (optional)

  """
  def list_test_cases(opts) do
    repo = Keyword.fetch!(opts, :repo)
    source_id = Keyword.get(opts, :source_id)

    query =
      from(tc in TestCase,
        preload: [:relevant_chunks, :source_chunk],
        order_by: [desc: tc.inserted_at]
      )

    query =
      if source_id do
        from(tc in query,
          join: c in assoc(tc, :source_chunk),
          join: d in assoc(c, :document),
          where: d.source_id == ^source_id
        )
      else
        query
      end

    repo.all(query)
  end

  @doc """
  Gets a single test case by ID.
  """
  def get_test_case(id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    repo.get(TestCase, id) |> repo.preload([:relevant_chunks, :source_chunk])
  end

  @doc """
  Creates a manual test case.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:question` - The question text (required)
    * `:relevant_chunk_ids` - List of chunk IDs considered relevant (required)
    * `:reference_answer` - Optional ground-truth answer text, used by
      correctness scoring in `run/1` when an `:answerer` is configured.

  """
  def create_test_case(opts) do
    repo = Keyword.fetch!(opts, :repo)
    question = Keyword.fetch!(opts, :question)
    chunk_ids = Keyword.fetch!(opts, :relevant_chunk_ids)
    reference_answer = Keyword.get(opts, :reference_answer)

    test_case =
      %TestCase{}
      |> TestCase.changeset(%{
        question: question,
        source: :manual,
        reference_answer: reference_answer
      })
      |> repo.insert!()

    # Link relevant chunks (convert UUIDs to binary for insert_all)
    entries =
      Enum.map(chunk_ids, fn id ->
        %{
          test_case_id: Ecto.UUID.dump!(test_case.id),
          chunk_id: Ecto.UUID.dump!(id)
        }
      end)

    repo.insert_all("arcana_evaluation_test_case_chunks", entries)

    {:ok, repo.preload(test_case, :relevant_chunks)}
  end

  @doc """
  Deletes a test case.
  """
  def delete_test_case(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.get(TestCase, id) do
      nil -> {:error, :not_found}
      test_case -> {:ok, repo.delete!(test_case)}
    end
  end

  @doc """
  Lists past evaluation runs.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:limit` - Maximum runs to return (default: 20)

  """
  def list_runs(opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 20)

    from(r in Run,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> repo.all()
  end

  @doc """
  Gets a single evaluation run by ID.
  """
  def get_run(id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    repo.get(Run, id)
  end

  @doc """
  Deletes an evaluation run.
  """
  def delete_run(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case repo.get(Run, id) do
      nil -> {:error, :not_found}
      run -> {:ok, repo.delete!(run)}
    end
  end

  @doc """
  Returns count of test cases.
  """
  def count_test_cases(opts) do
    repo = Keyword.fetch!(opts, :repo)
    repo.aggregate(TestCase, :count)
  end
end
