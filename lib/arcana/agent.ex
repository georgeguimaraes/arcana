defmodule Arcana.Agent do
  @moduledoc """
  Pipeline-based agentic RAG for Arcana.

  Compose steps via pipes with a context struct flowing through each transformation:

      Arcana.Agent.new(question, repo: MyRepo, llm: llm_fn)
      |> Arcana.Agent.search()
      |> Arcana.Agent.answer()

  ## Context

  The `Arcana.Agent.Context` struct flows through the pipeline, accumulating
  results at each step. Each step transforms the context and passes it on.

  ## Steps

  - `new/2` - Initialize context with question and options
  - `search/2` - Execute search, populate results
  - `answer/1` - Generate final answer from results

  ## Example

      llm = fn prompt ->
        # Call your LLM API
        {:ok, "Generated answer"}
      end

      ctx =
        Arcana.Agent.new("What is Elixir?", repo: MyApp.Repo, llm: llm)
        |> Arcana.Agent.search()
        |> Arcana.Agent.answer()

      ctx.answer
      # => "Generated answer"
  """

  alias Arcana.Agent.Context

  @doc """
  Creates a new agent context.

  ## Options

  - `:repo` (required) - The Ecto repo to use
  - `:llm` (required) - Function that takes a prompt and returns `{:ok, response}` or `{:error, reason}`
  - `:limit` - Maximum chunks to retrieve (default: 5)
  - `:threshold` - Minimum similarity threshold (default: 0.5)

  ## Example

      Agent.new("What is Elixir?", repo: MyApp.Repo, llm: &my_llm/1)
  """
  def new(question, opts) when is_binary(question) do
    %Context{
      question: question,
      repo: Keyword.fetch!(opts, :repo),
      llm: Keyword.fetch!(opts, :llm),
      limit: Keyword.get(opts, :limit, 5),
      threshold: Keyword.get(opts, :threshold, 0.5)
    }
  end

  @doc """
  Routes the question to relevant collections.

  Uses the LLM to decide which collection(s) are most relevant for
  the question. This allows searching only in relevant collections
  instead of searching everything.

  ## Options

  - `:collections` (required) - List of available collection names
  - `:prompt` - Custom prompt function `fn question, collections -> prompt_string end`

  ## Example

      ctx
      |> Agent.route(collections: ["docs", "api", "support"])
      |> Agent.search()
      |> Agent.answer()

  The selected collections are stored in `ctx.collections` and used by `search/2`.
  """
  def route(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def route(%Context{} = ctx, opts) do
    available_collections = Keyword.fetch!(opts, :collections)

    start_metadata = %{
      question: ctx.question,
      available_collections: available_collections
    }

    :telemetry.span([:arcana, :agent, :route], start_metadata, fn ->
      prompt =
        case Keyword.get(opts, :prompt) do
          nil -> default_route_prompt(ctx.question, available_collections)
          custom_fn -> custom_fn.(ctx.question, available_collections)
        end

      {collections, reasoning} =
        case ctx.llm.(prompt) do
          {:ok, response} ->
            case Jason.decode(response) do
              {:ok, %{"collections" => cols, "reasoning" => reason}}
              when is_list(cols) ->
                {cols, reason}

              {:ok, %{"collections" => cols}} when is_list(cols) ->
                {cols, nil}

              _ ->
                {available_collections, nil}
            end

          {:error, _} ->
            {available_collections, nil}
        end

      updated_ctx = %{ctx | collections: collections, routing_reasoning: reasoning}

      stop_metadata = %{
        selected_count: length(collections),
        selected_collections: collections
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp default_route_prompt(question, available_collections) do
    """
    Which collection(s) should be searched for this question?

    Question: "#{question}"

    Available collections: #{inspect(available_collections)}

    Return JSON only: {"collections": ["name1", "name2"], "reasoning": "..."}
    Select only the most relevant collection(s). If unsure, include all.
    """
  end

  @doc """
  Breaks a complex question into simpler sub-questions.

  Uses the LLM to analyze the question and split it into parts that can
  be searched independently. Simple questions are returned unchanged.

  ## Options

  - `:prompt` - Custom prompt function `fn question -> prompt_string end`

  ## Example

      ctx
      |> Agent.decompose()
      |> Agent.search()
      |> Agent.answer()

  The sub-questions are stored in `ctx.sub_questions` and used by `search/2`.
  """
  def decompose(ctx, opts \\ [])

  def decompose(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def decompose(%Context{} = ctx, opts) do
    start_metadata = %{question: ctx.question}

    :telemetry.span([:arcana, :agent, :decompose], start_metadata, fn ->
      prompt =
        case Keyword.get(opts, :prompt) do
          nil -> default_decompose_prompt(ctx.question)
          custom_fn -> custom_fn.(ctx.question)
        end

      sub_questions =
        case ctx.llm.(prompt) do
          {:ok, response} ->
            case Jason.decode(response) do
              {:ok, %{"sub_questions" => questions}} when is_list(questions) -> questions
              _ -> [ctx.question]
            end

          {:error, _} ->
            [ctx.question]
        end

      updated_ctx = %{ctx | sub_questions: sub_questions}

      stop_metadata = %{sub_question_count: length(sub_questions)}

      {updated_ctx, stop_metadata}
    end)
  end

  defp default_decompose_prompt(question) do
    """
    Break this question into simpler sub-questions that can be answered independently:

    "#{question}"

    Return JSON only: {"sub_questions": ["q1", "q2", ...], "reasoning": "..."}
    If the question is already simple, return: {"sub_questions": ["#{question}"], "reasoning": "simple question"}
    """
  end

  @doc """
  Executes search and populates results in the context.

  Uses `sub_questions` if present (from decompose step), otherwise uses the original question.
  Uses `collections` if present (from route step), otherwise searches the default collection.

  ## Options

  - `:self_correct` - Enable self-correcting search (default: false)
  - `:max_iterations` - Max retry attempts for self-correct (default: 3)
  - `:sufficient_prompt` - Custom prompt function `fn question, chunks -> prompt_string end`
  - `:rewrite_prompt` - Custom prompt function `fn question, chunks -> prompt_string end`

  ## Example

      ctx
      |> Agent.search()
      |> Agent.answer()

  ## Self-correcting search

  When `self_correct: true`, the agent will:
  1. Execute the search
  2. Ask the LLM if results are sufficient
  3. If not, rewrite the query and retry
  4. Repeat until sufficient or max_iterations reached
  """
  def search(ctx, opts \\ [])

  def search(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def search(%Context{} = ctx, opts) do
    self_correct = Keyword.get(opts, :self_correct, false)
    max_iterations = Keyword.get(opts, :max_iterations, 3)
    sufficient_prompt_fn = Keyword.get(opts, :sufficient_prompt)
    rewrite_prompt_fn = Keyword.get(opts, :rewrite_prompt)

    start_metadata = %{
      question: ctx.question,
      sub_questions: ctx.sub_questions,
      collections: ctx.collections,
      self_correct: self_correct
    }

    :telemetry.span([:arcana, :agent, :search], start_metadata, fn ->
      questions = ctx.sub_questions || [ctx.question]
      collections = ctx.collections || ["default"]

      prompt_opts = %{
        sufficient_prompt: sufficient_prompt_fn,
        rewrite_prompt: rewrite_prompt_fn
      }

      results =
        for question <- questions,
            collection <- collections do
          if self_correct do
            do_self_correcting_search(ctx, question, collection, max_iterations, prompt_opts)
          else
            chunks = do_simple_search(ctx, question, collection)
            %{question: question, collection: collection, chunks: chunks, iterations: 1}
          end
        end

      updated_ctx = %{ctx | results: results}
      total_chunks = results |> Enum.flat_map(& &1.chunks) |> length()
      total_iterations = results |> Enum.map(& &1.iterations) |> Enum.sum()

      stop_metadata = %{
        result_count: length(results),
        total_chunks: total_chunks,
        total_iterations: total_iterations
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp do_simple_search(ctx, question, collection) do
    Arcana.search(question,
      repo: ctx.repo,
      collection: collection,
      limit: ctx.limit,
      threshold: ctx.threshold
    )
  end

  defp do_self_correcting_search(ctx, question, collection, max_iterations, prompt_opts) do
    do_self_correcting_search(ctx, question, collection, max_iterations, prompt_opts, 1)
  end

  defp do_self_correcting_search(
         ctx,
         question,
         collection,
         max_iterations,
         _prompt_opts,
         iteration
       )
       when iteration > max_iterations do
    # Max iterations reached, return best effort
    chunks = do_simple_search(ctx, question, collection)
    %{question: question, collection: collection, chunks: chunks, iterations: max_iterations}
  end

  defp do_self_correcting_search(
         ctx,
         question,
         collection,
         max_iterations,
         prompt_opts,
         iteration
       ) do
    chunks = do_simple_search(ctx, question, collection)

    if sufficient_results?(ctx, question, chunks, prompt_opts.sufficient_prompt) do
      %{question: question, collection: collection, chunks: chunks, iterations: iteration}
    else
      case rewrite_query(ctx, question, chunks, prompt_opts.rewrite_prompt) do
        {:ok, rewritten_query} ->
          do_self_correcting_search(
            ctx,
            rewritten_query,
            collection,
            max_iterations,
            prompt_opts,
            iteration + 1
          )

        {:error, _} ->
          # Can't rewrite, return what we have
          %{question: question, collection: collection, chunks: chunks, iterations: iteration}
      end
    end
  end

  defp sufficient_results?(ctx, question, chunks, custom_prompt_fn) do
    prompt =
      case custom_prompt_fn do
        nil -> default_sufficient_prompt(question, chunks)
        fn_ref -> fn_ref.(question, chunks)
      end

    case ctx.llm.(prompt) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, %{"sufficient" => true}} -> true
          {:ok, %{"sufficient" => false}} -> false
          _ -> true
        end

      {:error, _} ->
        # On error, assume sufficient to avoid infinite loops
        true
    end
  end

  defp default_sufficient_prompt(question, chunks) do
    chunks_text =
      chunks
      |> Enum.map(& &1.text)
      |> Enum.join("\n---\n")

    """
    Question: "#{question}"

    Retrieved chunks:
    #{chunks_text}

    Are these chunks sufficient to answer the question?
    Return JSON only: {"sufficient": true} or {"sufficient": false, "reasoning": "..."}
    """
  end

  defp rewrite_query(ctx, question, chunks, custom_prompt_fn) do
    prompt =
      case custom_prompt_fn do
        nil -> default_rewrite_prompt(question, chunks)
        fn_ref -> fn_ref.(question, chunks)
      end

    case ctx.llm.(prompt) do
      {:ok, response} ->
        case Jason.decode(response) do
          {:ok, %{"query" => rewritten}} -> {:ok, rewritten}
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_rewrite_prompt(question, chunks) do
    chunks_text =
      chunks
      |> Enum.take(3)
      |> Enum.map(& &1.text)
      |> Enum.join("\n---\n")

    """
    The following search query did not return sufficient results:
    Query: "#{question}"

    Retrieved (insufficient) results:
    #{chunks_text}

    Rewrite the query to find better results.
    Return JSON only: {"query": "rewritten query here"}
    """
  end

  @doc """
  Generates the final answer from search results.

  Collects all chunks from results, deduplicates by ID, and prompts the LLM
  to generate an answer based on the context.

  ## Options

  - `:prompt` - Custom prompt function `fn question, chunks -> prompt_string end`

  ## Example

      ctx
      |> Agent.search()
      |> Agent.answer()

      ctx.answer
      # => "The answer based on retrieved context..."
  """
  def answer(ctx, opts \\ [])

  def answer(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def answer(%Context{} = ctx, opts) do
    start_metadata = %{question: ctx.question}

    :telemetry.span([:arcana, :agent, :answer], start_metadata, fn ->
      all_chunks =
        ctx.results
        |> Enum.flat_map(& &1.chunks)
        |> Enum.uniq_by(& &1.id)

      prompt =
        case Keyword.get(opts, :prompt) do
          nil -> default_answer_prompt(ctx.question, all_chunks)
          custom_fn -> custom_fn.(ctx.question, all_chunks)
        end

      updated_ctx =
        case ctx.llm.(prompt) do
          {:ok, answer} ->
            %{ctx | answer: answer, context_used: all_chunks}

          {:error, reason} ->
            %{ctx | error: reason}
        end

      stop_metadata = %{
        context_chunk_count: length(all_chunks),
        success: is_nil(updated_ctx.error)
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp default_answer_prompt(question, chunks) do
    context =
      chunks
      |> Enum.map(& &1.text)
      |> Enum.join("\n\n---\n\n")

    """
    Question: "#{question}"

    Context:
    #{context}

    Answer the question based on the context provided. If the context doesn't contain enough information, say so.
    """
  end
end
