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
  Executes search and populates results in the context.

  Uses `sub_questions` if present (from decompose step), otherwise uses the original question.
  Uses `collections` if present (from route step), otherwise searches the default collection.

  ## Options

  - `:self_correct` - Enable self-correcting search (default: false) - *not yet implemented*
  - `:max_iterations` - Max retry attempts for self-correct (default: 3) - *not yet implemented*

  ## Example

      ctx
      |> Agent.search()
      |> Agent.answer()
  """
  def search(ctx, opts \\ [])

  def search(%Context{error: error} = ctx, _opts) when not is_nil(error), do: ctx

  def search(%Context{} = ctx, _opts) do
    start_metadata = %{
      question: ctx.question,
      sub_questions: ctx.sub_questions,
      collections: ctx.collections
    }

    :telemetry.span([:arcana, :agent, :search], start_metadata, fn ->
      questions = ctx.sub_questions || [ctx.question]
      collections = ctx.collections || ["default"]

      results =
        for question <- questions,
            collection <- collections do
          chunks =
            Arcana.search(question,
              repo: ctx.repo,
              collection: collection,
              limit: ctx.limit,
              threshold: ctx.threshold
            )

          %{question: question, collection: collection, chunks: chunks}
        end

      updated_ctx = %{ctx | results: results}
      total_chunks = results |> Enum.flat_map(& &1.chunks) |> length()

      stop_metadata = %{
        result_count: length(results),
        total_chunks: total_chunks
      }

      {updated_ctx, stop_metadata}
    end)
  end

  @doc """
  Generates the final answer from search results.

  Collects all chunks from results, deduplicates by ID, and prompts the LLM
  to generate an answer based on the context.

  ## Example

      ctx
      |> Agent.search()
      |> Agent.answer()

      ctx.answer
      # => "The answer based on retrieved context..."
  """
  def answer(%Context{error: error} = ctx) when not is_nil(error), do: ctx

  def answer(%Context{} = ctx) do
    start_metadata = %{question: ctx.question}

    :telemetry.span([:arcana, :agent, :answer], start_metadata, fn ->
      all_chunks =
        ctx.results
        |> Enum.flat_map(& &1.chunks)
        |> Enum.uniq_by(& &1.id)

      prompt = build_answer_prompt(ctx.question, all_chunks)

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

  defp build_answer_prompt(question, chunks) do
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
