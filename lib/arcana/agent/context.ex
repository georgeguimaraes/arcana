defmodule Arcana.Agent.Context do
  @moduledoc """
  Context struct that flows through the agent pipeline.

  Each step in the pipeline reads from and writes to this struct,
  allowing steps to be composed via pipes.

  ## Fields

  ### Input (set by `new/2`)
  - `:question` - The original question
  - `:repo` - The Ecto repo to use
  - `:llm` - LLM function for generating answers

  ### Options
  - `:limit` - Maximum chunks to retrieve per search
  - `:threshold` - Minimum similarity threshold

  ### Populated by `rewrite/2`
  - `:rewritten_query` - Conversational input rewritten as a clear search query

  ### Populated by `select/2`
  - `:collections` - List of collection names to search
  - `:selection_reasoning` - LLM's reasoning for the selection decision

  ### Populated by `expand/2`
  - `:expanded_query` - Query expanded with synonyms and related terms

  ### Populated by `decompose/1`
  - `:sub_questions` - List of sub-questions to search separately

  ### Populated by `gate/2`
  - `:skip_retrieval` - If true, skip search and answer from LLM knowledge
  - `:gate_reasoning` - LLM's reasoning for the gate decision

  ### Populated by `search/2`
  - `:results` - List of `%{question: _, collection: _, chunks: _}` maps

  ### Populated by `reason/2`
  - `:queries_tried` - MapSet of queries already searched (prevents loops)
  - `:reason_iterations` - Number of reason iterations performed

  ### Populated by `rerank/2`
  - `:rerank_scores` - Map of chunk ID to score (for debugging/observability)

  ### Populated by `answer/1`
  - `:answer` - The generated answer
  - `:context_used` - Chunks used to generate the answer
  - `:correction_count` - Number of self-corrections performed (0 if disabled)
  - `:corrections` - List of `{answer, feedback}` tuples showing correction history

  ### Error handling
  - `:error` - Error reason if any step fails
  """

  defstruct [
    # Input
    :question,
    :repo,
    :llm,

    # Options
    :limit,
    :threshold,

    # Populated by rewrite/2
    :rewritten_query,

    # Populated by select/2
    :collections,
    :selection_reasoning,

    # Populated by expand/2
    :expanded_query,

    # Populated by decompose/1
    :sub_questions,

    # Populated by gate/2
    :skip_retrieval,
    :gate_reasoning,

    # Populated by search/2
    :results,

    # Populated by reason/2
    :queries_tried,
    :reason_iterations,

    # Populated by rerank/2
    :rerank_scores,

    # Populated by answer/1
    :answer,
    :context_used,
    :correction_count,
    :corrections,

    # Error handling
    :error
  ]
end
