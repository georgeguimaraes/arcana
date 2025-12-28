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
      {:ok, run} = Arcana.Evaluation.run(repo: MyApp.Repo, mode: :semantic)

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
    * `:mode` - Search mode :semantic | :fulltext | :hybrid (default: :semantic)
    * `:source_id` - Limit evaluation to specific source
    * `:evaluate_answers` - When true, also evaluates answer quality (default: false)
    * `:llm` - LLM function (required when evaluate_answers is true)

  """
  def run(opts) do
    repo = Keyword.fetch!(opts, :repo)
    mode = Keyword.get(opts, :mode, :semantic)
    source_id = Keyword.get(opts, :source_id)
    evaluate_answers = Keyword.get(opts, :evaluate_answers, false)
    llm = Keyword.get(opts, :llm)

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

      # Evaluate each test case
      case_results =
        Enum.map(test_cases, fn test_case ->
          evaluate_test_case(test_case, repo, mode, evaluate_answers, llm)
        end)

      # Aggregate metrics
      metrics = Metrics.aggregate(case_results)

      # Add answer metrics if evaluated
      metrics =
        if evaluate_answers do
          Map.put(metrics, :faithfulness, average_faithfulness(case_results))
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

  defp evaluate_test_case(test_case, repo, mode, evaluate_answers, llm) do
    search_results = Arcana.search(test_case.question, repo: repo, mode: mode, limit: 10)
    retrieval_metrics = Metrics.evaluate_case(test_case, search_results)

    if evaluate_answers do
      answer_metrics = evaluate_answer(test_case.question, search_results, llm)
      Map.merge(retrieval_metrics, answer_metrics)
    else
      retrieval_metrics
    end
  end

  defp average_faithfulness(case_results) do
    scores =
      case_results
      |> Enum.map(& &1.faithfulness_score)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(scores), do: 0.0, else: Enum.sum(scores) / length(scores)
  end

  defp evaluate_answer(question, search_results, llm) do
    alias Arcana.Evaluation.AnswerMetrics

    # Generate answer using the search results as context
    chunks_text = Enum.map_join(search_results, "\n\n", & &1.text)

    answer_prompt = """
    Answer the following question based only on the provided context.

    Context:
    #{chunks_text}

    Question: #{question}

    Answer:
    """

    answer =
      case Arcana.LLM.complete(llm, answer_prompt, []) do
        {:ok, response} -> response
        {:error, _} -> nil
      end

    # Evaluate faithfulness if we got an answer
    if answer do
      case AnswerMetrics.evaluate_faithfulness(question, search_results, answer, llm: llm) do
        {:ok, %{score: score, reasoning: reasoning}} ->
          %{
            answer: answer,
            faithfulness_score: score,
            faithfulness_reasoning: reasoning
          }

        {:error, _} ->
          %{answer: answer, faithfulness_score: nil, faithfulness_reasoning: nil}
      end
    else
      %{answer: nil, faithfulness_score: nil, faithfulness_reasoning: nil}
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

  """
  def create_test_case(opts) do
    repo = Keyword.fetch!(opts, :repo)
    question = Keyword.fetch!(opts, :question)
    chunk_ids = Keyword.fetch!(opts, :relevant_chunk_ids)

    test_case =
      %TestCase{}
      |> TestCase.changeset(%{question: question, source: :manual})
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
