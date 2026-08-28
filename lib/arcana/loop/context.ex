defmodule Arcana.Loop.Context do
  @moduledoc """
  State carried through an `Arcana.Loop` run.

  This is the loop's working memory. It accumulates chunks across iterations,
  records the tool history, and tracks termination state.

  ## Fields

    * `:question` - The original user question.
    * `:repo` - Ecto repo to use for retrieval tools.
    * `:collections` - Collection scope for retrieval tools. Either `:all`, one
      name, or a list of names, where `[]` matches no collections.
    * `:messages` - The `ReqLLM.Context` carrying the running conversation.
    * `:chunks` - Accumulated chunks from `search` tool calls (capped via `:chunk_cap`).
    * `:tool_history` - List of `%{tool, args, iteration, summary}` entries in call order.
    * `:iterations` - Number of LLM controller turns executed.
    * `:answer` - Final answer text once the loop terminates.
    * `:terminated_by` - One of `:answered`, `:gave_up`, `:max_iterations`, `:error`, or `nil`.
    * `:error` - Error reason when `terminated_by == :error`.
    * `:grounding` - Populated by `Arcana.Loop.ground/2` with an
      `%Arcana.Grounding.Result{}` scoring the answer against `ctx.chunks`.
      `nil` until grounding runs.
  """

  @type tool_history_entry :: %{
          tool: atom(),
          args: map(),
          iteration: non_neg_integer(),
          summary: String.t()
        }

  @type t :: %__MODULE__{
          question: String.t(),
          repo: module() | nil,
          collections: Arcana.CollectionScope.input(),
          messages: term() | nil,
          chunks: [map()],
          tool_history: [tool_history_entry()],
          iterations: non_neg_integer(),
          answer: String.t() | nil,
          terminated_by: atom() | nil,
          error: term() | nil,
          grounding: Arcana.Grounding.Result.t() | nil
        }

  defstruct question: nil,
            repo: nil,
            collections: :all,
            messages: nil,
            chunks: [],
            tool_history: [],
            iterations: 0,
            answer: nil,
            terminated_by: nil,
            error: nil,
            grounding: nil
end
