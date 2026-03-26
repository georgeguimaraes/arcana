defmodule Arcana.Recursive.Session do
  @moduledoc """
  Tracks state for a single Arcana.Recursive exploration run.

  The session flows through the tool-use loop, accumulating tool call
  traces, token usage, and workspace state. Each LLM call reads from
  and writes to this struct.
  """

  alias Arcana.Recursive.Workspace

  @default_max_steps 30
  def default_max_steps, do: @default_max_steps

  defstruct [
    :question,
    :model,
    :repo,
    :answer,
    :error,
    workspace: Workspace.new(),
    context: nil,
    tools: [],
    trace: [],
    usage: %{input_tokens: 0, output_tokens: 0},
    step_count: 0,
    max_steps: @default_max_steps,
    depth: 0,
    max_depth: 3,
    collections: ["default"],
    llm_opts: [],
    on_tool_call: nil,
    on_trace_entry: nil,
    session_id: "root"
  ]

  @type t :: %__MODULE__{
          question: String.t(),
          model: term(),
          repo: module() | nil,
          answer: String.t() | nil,
          error: term() | nil,
          workspace: Workspace.t(),
          context: ReqLLM.Context.t() | nil,
          tools: [ReqLLM.Tool.t()],
          trace: [map()],
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          step_count: non_neg_integer(),
          max_steps: pos_integer(),
          depth: non_neg_integer(),
          max_depth: pos_integer(),
          collections: [String.t()],
          llm_opts: keyword(),
          on_tool_call: (String.t(), map(), term() -> :ok) | nil,
          on_trace_entry: (map() -> :ok) | nil,
          session_id: String.t()
        }

  @doc "Adds a tool call entry to the trace."
  @spec record_tool_call(t(), String.t(), map(), term(), non_neg_integer()) :: t()
  def record_tool_call(%__MODULE__{} = session, tool_name, args, result_preview, duration_ms) do
    entry = %{
      step: session.step_count,
      tool: tool_name,
      args: args,
      result_preview: result_preview,
      duration_ms: duration_ms,
      depth: session.depth,
      session_id: session.session_id
    }

    if session.on_trace_entry, do: session.on_trace_entry.(entry)

    %{session | trace: session.trace ++ [entry]}
  end

  @doc "Accumulates token usage from an LLM response."
  @spec accumulate_usage(t(), map() | nil) :: t()
  def accumulate_usage(%__MODULE__{} = session, nil), do: session

  def accumulate_usage(%__MODULE__{} = session, response_usage) when is_map(response_usage) do
    input = Map.get(response_usage, :input_tokens, 0) + session.usage.input_tokens
    output = Map.get(response_usage, :output_tokens, 0) + session.usage.output_tokens
    %{session | usage: %{input_tokens: input, output_tokens: output}}
  end

  @doc "Increments the step counter."
  @spec increment_step(t()) :: t()
  def increment_step(%__MODULE__{} = session) do
    %{session | step_count: session.step_count + 1}
  end
end
