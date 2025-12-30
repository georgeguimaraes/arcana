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
  Rewrites conversational input into a clear search query.

  Uses the LLM to remove conversational noise (greetings, filler phrases)
  while preserving the core question and all important terms.

  This step should run before `expand/2` and `decompose/2` to clean up
  the input before further transformations.

  ## Options

  - `:rewriter` - Custom rewriter module or function (default: `Arcana.Agent.Rewriter.LLM`)
  - `:prompt` - Custom prompt function `fn question -> prompt_string end`
  - `:llm` - Override the LLM function for this step

  ## Example

      ctx
      |> Agent.rewrite()   # "Hey, tell me about Elixir" → "about Elixir"
      |> Agent.expand()
      |> Agent.search()
      |> Agent.answer()

  ## Custom Rewriter

      # Module implementing Arcana.Agent.Rewriter behaviour
      Agent.rewrite(ctx, rewriter: MyApp.RegexRewriter)

      # Inline function
      Agent.rewrite(ctx, rewriter: fn question, _opts ->
        {:ok, String.downcase(question)}
      end)
  """
  def rewrite(ctx, opts \\ [])

  def rewrite(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def rewrite(%Context{} = ctx, opts) do
    rewriter = Keyword.get(opts, :rewriter, Arcana.Agent.Rewriter.LLM)

    start_metadata = %{
      question: ctx.question,
      rewriter: rewriter_name(rewriter)
    }

    :telemetry.span([:arcana, :agent, :rewrite], start_metadata, fn ->
      llm = Keyword.get(opts, :llm, ctx.llm)
      rewriter_opts = Keyword.merge(opts, llm: llm)

      rewritten_query =
        case do_rewrite(rewriter, ctx.question, rewriter_opts) do
          {:ok, rewritten} -> rewritten
          {:error, _} -> nil
        end

      updated_ctx = %{ctx | rewritten_query: rewritten_query}

      stop_metadata = %{rewritten_query: rewritten_query}

      {updated_ctx, stop_metadata}
    end)
  end

  defp rewriter_name(rewriter) when is_atom(rewriter), do: rewriter
  defp rewriter_name(_rewriter), do: :custom_function

  defp do_rewrite(rewriter, question, opts) when is_atom(rewriter) do
    rewriter.rewrite(question, opts)
  end

  defp do_rewrite(rewriter, question, opts) when is_function(rewriter, 2) do
    rewriter.(question, opts)
  end

  # Returns the effective query to use, chaining through the pipeline:
  # expanded_query → rewritten_query → question
  defp effective_query(%Context{expanded_query: expanded}) when is_binary(expanded), do: expanded

  defp effective_query(%Context{rewritten_query: rewritten}) when is_binary(rewritten),
    do: rewritten

  defp effective_query(%Context{question: question}), do: question

  @doc """
  Selects which collection(s) to search for the question.

  By default, uses the LLM to decide which collection(s) are most relevant.
  You can provide a custom selector module or function for deterministic routing.

  Collection descriptions are automatically fetched from the database
  and passed to the selector.

  ## Options

  - `:collections` (required) - List of available collection names
  - `:selector` - Custom selector module or function (default: `Arcana.Agent.Selector.LLM`)
  - `:prompt` - Custom prompt function for LLM selector
  - `:context` - User context map passed to custom selectors

  ## Example

      # LLM-based selection (default)
      ctx
      |> Agent.select(collections: ["docs", "api", "support"])
      |> Agent.search()

      # Custom selector module
      ctx
      |> Agent.select(
        collections: ["docs", "api"],
        selector: MyApp.TeamBasedSelector,
        context: %{team: user.team}
      )

      # Inline selector function
      ctx
      |> Agent.select(
        collections: ["docs", "api"],
        selector: fn question, _collections, _opts ->
          if question =~ "API", do: {:ok, ["api"], "API query"}, else: {:ok, ["docs"], nil}
        end
      )

  The selected collections are stored in `ctx.collections` and used by `search/2`.
  """
  def select(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def select(%Context{} = ctx, opts) do
    collection_names = Keyword.fetch!(opts, :collections)
    collections_with_descriptions = fetch_collections(ctx.repo, collection_names)
    selector = Keyword.get(opts, :selector, Arcana.Agent.Selector.LLM)

    start_metadata = %{
      question: ctx.question,
      available_collections: collection_names,
      selector: selector_name(selector)
    }

    :telemetry.span([:arcana, :agent, :select], start_metadata, fn ->
      llm = Keyword.get(opts, :llm, ctx.llm)
      selector_opts = Keyword.merge(opts, llm: llm)

      {collections, reasoning} =
        do_select(selector, ctx.question, collections_with_descriptions, selector_opts)
        |> handle_select_result(collection_names)

      updated_ctx = %{ctx | collections: collections, selection_reasoning: reasoning}

      stop_metadata = %{
        selected_count: length(collections),
        selected_collections: collections
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp selector_name(selector) when is_atom(selector), do: selector
  defp selector_name(_selector), do: :custom_function

  defp do_select(selector, question, collections, opts) when is_atom(selector) do
    selector.select(question, collections, opts)
  end

  defp do_select(selector, question, collections, opts) when is_function(selector, 3) do
    selector.(question, collections, opts)
  end

  defp handle_select_result({:ok, collections, reasoning}, _fallback) do
    {collections, reasoning}
  end

  defp handle_select_result({:error, _reason}, fallback_collections) do
    {fallback_collections, nil}
  end

  defp fetch_collections(repo, names) do
    import Ecto.Query

    query = from(c in Arcana.Collection, where: c.name in ^names, select: {c.name, c.description})

    db_collections = repo.all(query) |> Map.new()

    Enum.map(names, fn name ->
      {name, Map.get(db_collections, name)}
    end)
  end

  @doc """
  Expands the query with synonyms and related terms.

  Uses the LLM to add related terms and synonyms that may help
  find more relevant documents. The expanded query is used by `search/2`
  if present.

  ## Options

  - `:expander` - Custom expander module or function (default: `Arcana.Agent.Expander.LLM`)
  - `:prompt` - Custom prompt function `fn question -> prompt_string end`
  - `:llm` - Override the LLM function for this step

  ## Example

      ctx
      |> Agent.expand()
      |> Agent.search()
      |> Agent.answer()

  The expanded query is stored in `ctx.expanded_query` and used by `search/2`.

  ## Custom Expander

      # Module implementing Arcana.Agent.Expander behaviour
      Agent.expand(ctx, expander: MyApp.ThesaurusExpander)

      # Inline function
      Agent.expand(ctx, expander: fn question, _opts ->
        {:ok, question <> " programming development"}
      end)
  """
  def expand(ctx, opts \\ [])

  def expand(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def expand(%Context{} = ctx, opts) do
    query = effective_query(ctx)
    expander = Keyword.get(opts, :expander, Arcana.Agent.Expander.LLM)

    start_metadata = %{
      question: query,
      expander: expander_name(expander)
    }

    :telemetry.span([:arcana, :agent, :expand], start_metadata, fn ->
      llm = Keyword.get(opts, :llm, ctx.llm)
      expander_opts = Keyword.merge(opts, llm: llm)

      expanded_query =
        case do_expand(expander, query, expander_opts) do
          {:ok, expanded} -> expanded
          {:error, _} -> nil
        end

      updated_ctx = %{ctx | expanded_query: expanded_query}

      stop_metadata = %{expanded_query: expanded_query}

      {updated_ctx, stop_metadata}
    end)
  end

  defp expander_name(expander) when is_atom(expander), do: expander
  defp expander_name(_expander), do: :custom_function

  defp do_expand(expander, question, opts) when is_atom(expander) do
    expander.expand(question, opts)
  end

  defp do_expand(expander, question, opts) when is_function(expander, 2) do
    expander.(question, opts)
  end

  @doc """
  Breaks a complex question into simpler sub-questions.

  Uses the LLM to analyze the question and split it into parts that can
  be searched independently. Simple questions are returned unchanged.

  ## Options

  - `:decomposer` - Custom decomposer module or function (default: `Arcana.Agent.Decomposer.LLM`)
  - `:prompt` - Custom prompt function `fn question -> prompt_string end`
  - `:llm` - Override the LLM function for this step

  ## Example

      ctx
      |> Agent.decompose()
      |> Agent.search()
      |> Agent.answer()

  The sub-questions are stored in `ctx.sub_questions` and used by `search/2`.

  ## Custom Decomposer

      # Module implementing Arcana.Agent.Decomposer behaviour
      Agent.decompose(ctx, decomposer: MyApp.KeywordDecomposer)

      # Inline function
      Agent.decompose(ctx, decomposer: fn question, _opts ->
        {:ok, [question]}  # No decomposition
      end)
  """
  def decompose(ctx, opts \\ [])

  def decompose(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def decompose(%Context{} = ctx, opts) do
    query = effective_query(ctx)
    decomposer = Keyword.get(opts, :decomposer, Arcana.Agent.Decomposer.LLM)

    start_metadata = %{
      question: query,
      decomposer: decomposer_name(decomposer)
    }

    :telemetry.span([:arcana, :agent, :decompose], start_metadata, fn ->
      llm = Keyword.get(opts, :llm, ctx.llm)
      decomposer_opts = Keyword.merge(opts, llm: llm)

      sub_questions =
        case do_decompose(decomposer, query, decomposer_opts) do
          {:ok, questions} -> questions
          {:error, _} -> [query]
        end

      updated_ctx = %{ctx | sub_questions: sub_questions}

      stop_metadata = %{sub_question_count: length(sub_questions)}

      {updated_ctx, stop_metadata}
    end)
  end

  defp decomposer_name(decomposer) when is_atom(decomposer), do: decomposer
  defp decomposer_name(_decomposer), do: :custom_function

  defp do_decompose(decomposer, question, opts) when is_atom(decomposer) do
    decomposer.decompose(question, opts)
  end

  defp do_decompose(decomposer, question, opts) when is_function(decomposer, 2) do
    decomposer.(question, opts)
  end

  @doc """
  Executes search and populates results in the context.

  Uses `sub_questions` if present (from decompose step), otherwise uses the original question.

  ## Collection Selection

  Collections are determined in this priority order:
  1. `:collection` or `:collections` option passed to this function
  2. `ctx.collections` (set by `select/2` if LLM selection was used)
  3. Falls back to `"default"` collection

  This allows you to explicitly specify a collection without using LLM-based selection:

      # Search a specific collection
      ctx |> Agent.search(collection: "technical_docs")

      # Search multiple specific collections
      ctx |> Agent.search(collections: ["docs", "faq"])

  ## Options

  - `:searcher` - Custom searcher module or function (default: `Arcana.Agent.Searcher.Arcana`)
  - `:collection` - Single collection name to search (string)
  - `:collections` - List of collection names to search
  - `:self_correct` - Enable self-correcting search (default: false)
  - `:max_iterations` - Max retry attempts for self-correct (default: 3)
  - `:sufficient_prompt` - Custom prompt function `fn question, chunks -> prompt_string end`
  - `:rewrite_prompt` - Custom prompt function `fn question, chunks -> prompt_string end`

  ## Examples

      # Basic search (uses default collection)
      ctx |> Agent.search() |> Agent.answer()

      # Search specific collection
      ctx |> Agent.search(collection: "products") |> Agent.answer()

      # With pipeline options
      ctx
      |> Agent.expand()
      |> Agent.search(collection: "docs", self_correct: true)
      |> Agent.answer()

  ## Custom Searcher

      # Module implementing Arcana.Agent.Searcher behaviour
      Agent.search(ctx, searcher: MyApp.ElasticsearchSearcher)

      # Inline function
      Agent.search(ctx, searcher: fn question, collection, opts ->
        {:ok, my_search(question, collection, opts)}
      end)

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
    searcher = Keyword.get(opts, :searcher, Arcana.Agent.Searcher.Arcana)
    self_correct = Keyword.get(opts, :self_correct, false)
    max_iterations = Keyword.get(opts, :max_iterations, 3)
    sufficient_prompt_fn = Keyword.get(opts, :sufficient_prompt)
    rewrite_prompt_fn = Keyword.get(opts, :rewrite_prompt)

    # Collection priority: option > ctx.collections > default
    collections =
      cond do
        Keyword.has_key?(opts, :collections) -> Keyword.get(opts, :collections)
        Keyword.has_key?(opts, :collection) -> [Keyword.get(opts, :collection)]
        ctx.collections != nil -> ctx.collections
        true -> ["default"]
      end

    start_metadata = %{
      question: ctx.question,
      sub_questions: ctx.sub_questions,
      collections: collections,
      searcher: searcher_name(searcher),
      self_correct: self_correct
    }

    :telemetry.span([:arcana, :agent, :search], start_metadata, fn ->
      questions = ctx.sub_questions || [ctx.expanded_query || ctx.question]

      search_opts = %{
        searcher: searcher,
        searcher_opts: [repo: ctx.repo, limit: ctx.limit, threshold: ctx.threshold],
        sufficient_prompt: sufficient_prompt_fn,
        rewrite_prompt: rewrite_prompt_fn
      }

      results =
        for question <- questions,
            collection <- collections do
          if self_correct do
            do_self_correcting_search(ctx, question, collection, max_iterations, search_opts)
          else
            chunks = do_simple_search(searcher, question, collection, search_opts.searcher_opts)
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

  defp searcher_name(searcher) when is_atom(searcher), do: searcher
  defp searcher_name(_searcher), do: :custom_function

  defp do_simple_search(searcher, question, collection, opts) when is_atom(searcher) do
    case searcher.search(question, collection, opts) do
      {:ok, chunks} -> chunks
      {:error, _} -> []
    end
  end

  defp do_simple_search(searcher, question, collection, opts) when is_function(searcher, 3) do
    case searcher.(question, collection, opts) do
      {:ok, chunks} -> chunks
      {:error, _} -> []
    end
  end

  defp do_self_correcting_search(ctx, question, collection, max_iterations, search_opts) do
    do_self_correcting_search(ctx, question, collection, max_iterations, search_opts, 1)
  end

  defp do_self_correcting_search(
         _ctx,
         question,
         collection,
         max_iterations,
         search_opts,
         iteration
       )
       when iteration > max_iterations do
    # Max iterations reached, return best effort
    chunks =
      do_simple_search(search_opts.searcher, question, collection, search_opts.searcher_opts)

    %{question: question, collection: collection, chunks: chunks, iterations: max_iterations}
  end

  defp do_self_correcting_search(
         ctx,
         question,
         collection,
         max_iterations,
         search_opts,
         iteration
       ) do
    chunks =
      do_simple_search(search_opts.searcher, question, collection, search_opts.searcher_opts)

    if sufficient_results?(ctx, question, chunks, search_opts.sufficient_prompt) do
      %{question: question, collection: collection, chunks: chunks, iterations: iteration}
    else
      case rewrite_query(ctx, question, chunks, search_opts.rewrite_prompt) do
        {:ok, rewritten_query} ->
          do_self_correcting_search(
            ctx,
            rewritten_query,
            collection,
            max_iterations,
            search_opts,
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

    case Arcana.LLM.complete(ctx.llm, prompt, [], []) do
      {:ok, response} ->
        case JSON.decode(response) do
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
    chunks_text = Enum.map_join(chunks, "\n---\n", & &1.text)

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

    case Arcana.LLM.complete(ctx.llm, prompt, [], []) do
      {:ok, response} ->
        case JSON.decode(response) do
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
      |> Enum.map_join("\n---\n", & &1.text)

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
  Re-ranks search results to improve quality before answering.

  Scores each chunk based on relevance to the question, filters by threshold,
  and re-sorts by score. Uses `Arcana.Reranker.LLM` by default.

  ## Options

  - `:reranker` - Custom reranker module or function (default: `Arcana.Reranker.LLM`)
  - `:threshold` - Minimum score to keep (default: 7, range 0-10)
  - `:prompt` - Custom prompt function for LLM reranker `fn question, chunk_text -> prompt end`

  ## Example

      ctx
      |> Agent.search()
      |> Agent.rerank()
      |> Agent.answer()

  ## Custom Reranker

      # Module implementing Arcana.Reranker behaviour
      Agent.rerank(ctx, reranker: MyApp.CrossEncoderReranker)

      # Inline function
      Agent.rerank(ctx, reranker: fn question, chunks, opts ->
        {:ok, my_rerank(question, chunks)}
      end)

  The reranked results replace `ctx.results`, and scores are stored in `ctx.rerank_scores`.
  """
  def rerank(ctx, opts \\ [])

  def rerank(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def rerank(%Context{results: nil} = ctx, _opts), do: %{ctx | results: [], rerank_scores: %{}}

  def rerank(%Context{results: []} = ctx, _opts), do: %{ctx | rerank_scores: %{}}

  def rerank(%Context{} = ctx, opts) do
    reranker = Keyword.get(opts, :reranker, Arcana.Agent.Reranker.LLM)
    threshold = Keyword.get(opts, :threshold, 7)
    prompt_fn = Keyword.get(opts, :prompt)

    start_metadata = %{
      question: ctx.question,
      reranker: reranker_name(reranker)
    }

    :telemetry.span([:arcana, :agent, :rerank], start_metadata, fn ->
      all_chunks_before =
        ctx.results
        |> Enum.flat_map(& &1.chunks)

      llm = Keyword.get(opts, :llm, ctx.llm)
      reranker_opts = [llm: llm, threshold: threshold, prompt: prompt_fn]

      {reranked_chunks, scores} =
        case do_rerank(reranker, ctx.question, all_chunks_before, reranker_opts) do
          {:ok, chunks} -> {chunks, build_scores_map(chunks)}
          {:error, _reason} -> {all_chunks_before, %{}}
        end

      # Update results with reranked chunks (flattened into single result)
      updated_results =
        if Enum.empty?(reranked_chunks) do
          []
        else
          [%{question: ctx.question, collection: "reranked", chunks: reranked_chunks}]
        end

      updated_ctx = %{ctx | results: updated_results, rerank_scores: scores}

      stop_metadata = %{
        chunks_before: length(all_chunks_before),
        chunks_after: length(reranked_chunks)
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp reranker_name(reranker) when is_atom(reranker), do: reranker
  defp reranker_name(_reranker), do: :custom_function

  defp do_rerank(reranker, question, chunks, opts) when is_atom(reranker) do
    reranker.rerank(question, chunks, opts)
  end

  defp do_rerank(reranker, question, chunks, opts) when is_function(reranker, 3) do
    reranker.(question, chunks, opts)
  end

  # Build scores map from reranked order (higher position = higher score)
  defp build_scores_map(chunks) do
    chunks
    |> Enum.with_index()
    |> Map.new(fn {chunk, idx} -> {chunk.id, length(chunks) - idx} end)
  end

  @doc """
  Generates the final answer from search results.

  Collects all chunks from results, deduplicates by ID, and prompts the LLM
  to generate an answer based on the context.

  ## Options

  - `:answerer` - Custom answerer module or function (default: `Arcana.Agent.Answerer.LLM`)
  - `:prompt` - Custom prompt function `fn question, chunks -> prompt_string end`
  - `:llm` - Override the LLM function for this step
  - `:self_correct` - Enable self-correcting answers (default: false)
  - `:max_corrections` - Max correction attempts (default: 2)

  ## Example

      ctx
      |> Agent.search()
      |> Agent.answer()

      ctx.answer
      # => "The answer based on retrieved context..."

  ## Custom Answerer

      # Module implementing Arcana.Agent.Answerer behaviour
      Agent.answer(ctx, answerer: MyApp.TemplateAnswerer)

      # Inline function
      Agent.answer(ctx, answerer: fn question, chunks, opts ->
        llm = Keyword.fetch!(opts, :llm)
        prompt = "Q: " <> question <> "\nContext: " <> inspect(chunks)
        Arcana.LLM.complete(llm, prompt, [], [])
      end)
  """
  def answer(ctx, opts \\ [])

  def answer(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def answer(%Context{} = ctx, opts) do
    answerer = Keyword.get(opts, :answerer, Arcana.Agent.Answerer.LLM)

    start_metadata = %{
      question: ctx.question,
      answerer: answerer_name(answerer)
    }

    :telemetry.span([:arcana, :agent, :answer], start_metadata, fn ->
      llm = Keyword.get(opts, :llm, ctx.llm)
      self_correct = Keyword.get(opts, :self_correct, false)
      max_corrections = Keyword.get(opts, :max_corrections, 2)
      custom_prompt_fn = Keyword.get(opts, :prompt)

      all_chunks =
        ctx.results
        |> Enum.flat_map(& &1.chunks)
        |> Enum.uniq_by(& &1.id)

      answerer_opts = Keyword.merge(opts, llm: llm)

      updated_ctx =
        handle_answer_result(
          do_answer(answerer, ctx.question, all_chunks, answerer_opts),
          ctx,
          all_chunks,
          self_correct,
          llm,
          max_corrections,
          custom_prompt_fn
        )

      stop_metadata = %{
        context_chunk_count: length(all_chunks),
        correction_count: updated_ctx.correction_count || 0,
        success: is_nil(updated_ctx.error)
      }

      {updated_ctx, stop_metadata}
    end)
  end

  defp answerer_name(answerer) when is_atom(answerer), do: answerer
  defp answerer_name(_answerer), do: :custom_function

  defp handle_answer_result(
         {:ok, answer},
         ctx,
         chunks,
         self_correct,
         llm,
         max_corrections,
         custom_prompt_fn
       ) do
    base_ctx = %{ctx | answer: answer, context_used: chunks}

    if self_correct do
      do_self_correct(base_ctx, llm, chunks, max_corrections, custom_prompt_fn)
    else
      %{base_ctx | correction_count: 0, corrections: []}
    end
  end

  defp handle_answer_result({:error, reason}, ctx, _chunks, _self_correct, _llm, _max, _prompt_fn) do
    %{ctx | error: reason}
  end

  defp do_answer(answerer, question, chunks, opts) when is_atom(answerer) do
    answerer.answer(question, chunks, opts)
  end

  defp do_answer(answerer, question, chunks, opts) when is_function(answerer, 3) do
    answerer.(question, chunks, opts)
  end

  defp do_self_correct(ctx, llm, chunks, max_corrections, custom_prompt_fn) do
    correction_opts = %{
      llm: llm,
      chunks: chunks,
      max: max_corrections,
      prompt_fn: custom_prompt_fn
    }

    do_self_correct_loop(ctx, correction_opts, 0, [])
  end

  defp do_self_correct_loop(ctx, %{max: max}, count, history) when count >= max do
    %{ctx | correction_count: count, corrections: Enum.reverse(history)}
  end

  defp do_self_correct_loop(ctx, correction_opts, count, history) do
    %{llm: llm, chunks: chunks} = correction_opts

    :telemetry.span([:arcana, :agent, :self_correct], %{attempt: count + 1}, fn ->
      evaluate_answer(llm, ctx.question, ctx.answer, chunks)
      |> handle_evaluation_result(ctx, correction_opts, count, history)
    end)
  end

  defp handle_evaluation_result({:ok, :grounded}, ctx, _opts, count, history) do
    result = %{ctx | correction_count: count, corrections: Enum.reverse(history)}
    {result, %{result: :accepted, attempt: count + 1}}
  end

  defp handle_evaluation_result({:ok, {:needs_improvement, feedback}}, ctx, opts, count, history) do
    %{llm: llm, chunks: chunks} = opts
    correction_prompt = build_correction_prompt(ctx.question, chunks, ctx.answer, feedback)

    case llm.(correction_prompt) do
      {:ok, new_answer} ->
        new_history = [{ctx.answer, feedback} | history]
        new_ctx = %{ctx | answer: new_answer}
        result = do_self_correct_loop(new_ctx, opts, count + 1, new_history)
        {result, %{result: :corrected, attempt: count + 1}}

      {:error, reason} ->
        result = %{
          ctx
          | error: reason,
            correction_count: count,
            corrections: Enum.reverse(history)
        }

        {result, %{result: :error, attempt: count + 1}}
    end
  end

  defp handle_evaluation_result({:error, _reason}, ctx, _opts, count, history) do
    # If evaluation fails, accept the current answer
    result = %{ctx | correction_count: count, corrections: Enum.reverse(history)}
    {result, %{result: :eval_failed, attempt: count + 1}}
  end

  defp evaluate_answer(llm, question, answer, chunks) do
    context = Enum.map_join(chunks, "\n\n", & &1.text)

    prompt = """
    Evaluate if the following answer is well-grounded in the provided context.

    Question: "#{question}"

    Context:
    #{context}

    Answer to evaluate:
    #{answer}

    Respond with JSON:
    - If the answer is well-grounded and accurate: {"grounded": true}
    - If the answer needs improvement: {"grounded": false, "feedback": "specific feedback on what to improve"}

    Only mark as not grounded if there are clear issues like:
    - Claims not supported by the context
    - Missing key information from the context
    - Factual errors

    JSON response:
    """

    case Arcana.LLM.complete(llm, prompt, [], []) do
      {:ok, response} ->
        parse_evaluation_response(response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_evaluation_response(response) do
    case Jason.decode(response) do
      {:ok, %{"grounded" => true}} ->
        {:ok, :grounded}

      {:ok, %{"grounded" => false, "feedback" => feedback}} ->
        {:ok, {:needs_improvement, feedback}}

      {:ok, %{"grounded" => false}} ->
        {:ok,
         {:needs_improvement,
          "Please ensure the answer is well-grounded in the provided context."}}

      {:error, _} ->
        # Try to extract JSON from response
        case Regex.run(~r/\{[^}]+\}/, response) do
          [json_str] -> parse_evaluation_response(json_str)
          _ -> {:ok, :grounded}
        end
    end
  end

  defp build_correction_prompt(question, chunks, previous_answer, feedback) do
    context = Enum.map_join(chunks, "\n\n---\n\n", & &1.text)

    """
    Question: "#{question}"

    Context:
    #{context}

    Your previous answer:
    #{previous_answer}

    Feedback on your answer:
    #{feedback}

    Please provide an improved answer that addresses the feedback. Ensure your answer is well-grounded in the provided context.
    """
  end
end
