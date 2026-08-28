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

  alias Arcana.{Collection, CollectionScope, Document}
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
    * `:run_ref` - Opaque term echoed back in the per-test-case telemetry
      metadata. `[:arcana, :evaluation, :test_case, :*]` events carry the
      question being evaluated, and handlers are global, so a listener that
      wants only its own run's questions has to filter on something; this
      is it.
    * `:collection` / `:collections` - `:all`, one collection name, or a list
      of collection names to confine the run to. The options are mutually
      exclusive. An empty list runs no test cases. The scope controls which
      test cases run (see `list_test_cases/1`), is forwarded to
      the retriever so retrieval can't reach outside those collections, and
      is recorded on the run so scoped listings can find it again.
      Retrieval then runs with `strict_collections: true` unless
      `:strict_collections` says otherwise, so a collection name with no
      row fails the search instead of widening it to the whole corpus.

  """
  def run(opts) do
    repo = Keyword.fetch!(opts, :repo)
    mode = Arcana.Search.normalize_mode(Keyword.get(opts, :mode, :vector))
    source_id = Keyword.get(opts, :source_id)
    evaluate_answers = Keyword.get(opts, :evaluate_answers, false)
    llm = Keyword.get(opts, :llm)
    collection_scope = CollectionScope.from_opts!(opts, :all)
    run_ref = Keyword.get(opts, :run_ref)
    retriever = Keyword.get(opts, :retriever, &default_retriever/2)

    retriever_opts =
      [repo: repo, mode: mode, limit: 10] ++ retrieval_scope_opts(opts, collection_scope)

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
        |> put_run_collections(collection_scope)

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
              run_ref: run_ref,
              index: index,
              total: total,
              question: test_case.question
            }
          )

          started_at = System.monotonic_time()

          result =
            evaluate_test_case(test_case, retriever_opts, evaluate_answers, llm, retriever)

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
              run_ref: run_ref,
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

  # Retrieval scope for the run. Passing `:collections` without strict
  # resolution would let a collection name with no row resolve to "no
  # filter", which is the whole corpus — the opposite of what a scoped run
  # asked for.
  defp retrieval_scope_opts(_opts, :all), do: []

  defp retrieval_scope_opts(opts, {:only, collections}) do
    [
      collections: collections,
      strict_collections: Keyword.get(opts, :strict_collections, true)
    ]
  end

  defp put_run_collections(config, :all), do: config

  defp put_run_collections(config, {:only, collections}) do
    Map.put(config, :collections, collections)
  end

  defp evaluate_test_case(test_case, retriever_opts, evaluate_answers, llm, retriever) do
    {search_results, pre_generated_answer} =
      case retriever.(test_case.question, retriever_opts) do
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
    * `:collection` / `:collections` - `:all`, one collection name, or a list
      of collection names to scope the listing to. The options are mutually
      exclusive. See "Collection scoping" below.

  ## Collection scoping

  A test case has no collection of its own: it reaches one through its
  chunks (the relevant chunks it is scored against, and the source chunk it
  was generated from). When `:collections` is given, only test cases whose
  every linked chunk resolves to one of those collections are returned, and
  at least one link has to resolve. Anything else — a test case straddling
  two collections, one whose chunks were deleted, one with no links at all
  — stays hidden, since rendering it would expose the foreign half.

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

    query
    |> scope_test_cases(CollectionScope.from_opts!(opts, :all))
    |> repo.all()
  end

  @doc """
  Gets a single test case by ID.

  Accepts the same `:collections` scoping option as `list_test_cases/1`;
  a test case outside the scope reads as missing.
  """
  def get_test_case(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case Ecto.UUID.cast(id) do
      :error ->
        nil

      {:ok, uuid} ->
        from(tc in TestCase,
          where: tc.id == ^uuid,
          preload: [:relevant_chunks, :source_chunk]
        )
        |> scope_test_cases(CollectionScope.from_opts!(opts, :all))
        |> repo.one()
    end
  end

  defp scope_test_cases(query, :all), do: query

  defp scope_test_cases(query, {:only, collections}) do
    from(tc in query, where: tc.id in subquery(scoped_test_case_ids(collections)))
  end

  # Every linked chunk has to land inside the allowed collections, and at
  # least one has to land there at all. The correlations live inside this
  # standalone SELECT so callers can use it from `delete_all` too.
  defp scoped_test_case_ids(collections) do
    from(tc in TestCase,
      as: :scoped_test_case,
      where:
        exists(allowed_chunks_query(collections)) or
          exists(allowed_source_chunk_query(collections)),
      where: not exists(foreign_chunks_query(collections)),
      where: not exists(foreign_source_chunk_query(collections)),
      select: tc.id
    )
  end

  defp allowed_chunks_query(collections) do
    from(tc in TestCase,
      join: chunk in assoc(tc, :relevant_chunks),
      join: doc in assoc(chunk, :document),
      join: col in assoc(doc, :collection),
      where: tc.id == parent_as(:scoped_test_case).id,
      where: col.name in ^collections,
      select: 1
    )
  end

  defp allowed_source_chunk_query(collections) do
    from(tc in TestCase,
      join: chunk in assoc(tc, :source_chunk),
      join: doc in assoc(chunk, :document),
      join: col in assoc(doc, :collection),
      where: tc.id == parent_as(:scoped_test_case).id,
      where: col.name in ^collections,
      select: 1
    )
  end

  # Left joins on purpose: a chunk whose document or collection is gone has
  # no readable collection, so it counts as foreign rather than dropping out
  # of the check.
  defp foreign_chunks_query(collections) do
    from(tc in TestCase,
      join: chunk in assoc(tc, :relevant_chunks),
      left_join: doc in Document,
      on: chunk.document_id == doc.id,
      left_join: col in Collection,
      on: doc.collection_id == col.id,
      where: tc.id == parent_as(:scoped_test_case).id,
      where: is_nil(col.name) or col.name not in ^collections,
      select: 1
    )
  end

  defp foreign_source_chunk_query(collections) do
    from(tc in TestCase,
      join: chunk in assoc(tc, :source_chunk),
      left_join: doc in Document,
      on: chunk.document_id == doc.id,
      left_join: col in Collection,
      on: doc.collection_id == col.id,
      where: tc.id == parent_as(:scoped_test_case).id,
      where: is_nil(col.name) or col.name not in ^collections,
      select: 1
    )
  end

  # Runs carry no collection either, and unlike test cases they have nothing
  # to derive one from, so `run/1` records the scope it ran under in the run
  # config. A scoped listing only sees runs whose recorded scope is a
  # non-empty subset of what the caller may read: unscoped runs (an
  # unrestricted dashboard's, or any run predating this) stay hidden.
  defp scope_runs(query, :all), do: query

  defp scope_runs(query, {:only, collections}) do
    from(r in query,
      where: fragment("jsonb_typeof(?->'collections') = 'array'", r.config),
      where: fragment("?->'collections' <> '[]'::jsonb", r.config),
      where: fragment("?->'collections' <@ to_jsonb(?::text[])", r.config, ^collections)
    )
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

  With `:collections`, the scope predicate rides inside the DELETE, so a
  test case outside the allowed collections is rejected with
  `{:error, :not_found}` and nothing can change between the check and the
  delete. A malformed id is rejected the same way.
  """
  def delete_test_case(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with {:ok, uuid} <- cast_id(id) do
      from(tc in TestCase, where: tc.id == ^uuid, select: tc)
      |> scope_test_cases(CollectionScope.from_opts!(opts, :all))
      |> delete_one(repo)
    end
  end

  @doc """
  Lists past evaluation runs.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:limit` - Maximum runs to return (default: 20)
    * `:collections` - Only list runs recorded as having run under a
      non-empty subset of these collection names

  """
  def list_runs(opts) do
    repo = Keyword.fetch!(opts, :repo)
    limit = Keyword.get(opts, :limit, 20)

    from(r in Run,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit
    )
    |> scope_runs(CollectionScope.from_opts!(opts, :all))
    |> repo.all()
  end

  @doc """
  Gets a single evaluation run by ID.

  Accepts the same `:collections` scoping option as `list_runs/1`.
  """
  def get_run(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    case cast_id(id) do
      {:ok, uuid} ->
        from(r in Run, where: r.id == ^uuid)
        |> scope_runs(CollectionScope.from_opts!(opts, :all))
        |> repo.one()

      {:error, :not_found} ->
        nil
    end
  end

  @doc """
  Deletes an evaluation run.

  Scoped the same way as `delete_test_case/2`.
  """
  def delete_run(id, opts) do
    repo = Keyword.fetch!(opts, :repo)

    with {:ok, uuid} <- cast_id(id) do
      from(r in Run, where: r.id == ^uuid, select: r)
      |> scope_runs(CollectionScope.from_opts!(opts, :all))
      |> delete_one(repo)
    end
  end

  @doc """
  Returns count of test cases.

  Accepts the same `:collections` scoping option as `list_test_cases/1`.
  """
  def count_test_cases(opts) do
    repo = Keyword.fetch!(opts, :repo)

    from(tc in TestCase, select: count(tc.id))
    |> scope_test_cases(CollectionScope.from_opts!(opts, :all))
    |> repo.one() || 0
  end

  # A forged id that isn't a UUID can't match anything, so it's rejected
  # before it reaches a query that would raise on the cast.
  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp delete_one(query, repo) do
    case repo.delete_all(query) do
      {0, _} -> {:error, :not_found}
      {_count, [record | _]} -> {:ok, record}
    end
  end
end
