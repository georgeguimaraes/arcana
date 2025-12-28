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

  ### Populated by `select/2`
  - `:collections` - List of collection names to search
  - `:selection_reasoning` - LLM's reasoning for the selection decision

  ### Populated by `expand/2`
  - `:expanded_query` - Query expanded with synonyms and related terms

  ### Populated by `decompose/1`
  - `:sub_questions` - List of sub-questions to search separately

  ### Populated by `search/2`
  - `:results` - List of `%{question: _, collection: _, chunks: _}` maps

  ### Populated by `answer/1`
  - `:answer` - The generated answer
  - `:context_used` - Chunks used to generate the answer

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

    # Populated by select/2
    :collections,
    :selection_reasoning,

    # Populated by expand/2
    :expanded_query,

    # Populated by decompose/1
    :sub_questions,

    # Populated by search/2
    :results,

    # Populated by answer/1
    :answer,
    :context_used,

    # Error handling
    :error
  ]
end
