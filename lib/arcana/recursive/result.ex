defmodule Arcana.Recursive.Result do
  @moduledoc """
  The result of an Arcana.Recursive exploration.
  """

  alias Arcana.Recursive.Workspace

  defstruct [
    :answer,
    :workspace,
    trace: [],
    usage: %{input_tokens: 0, output_tokens: 0},
    depth: 0,
    step_count: 0
  ]

  @type t :: %__MODULE__{
          answer: String.t(),
          workspace: Workspace.t(),
          trace: [map()],
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()},
          depth: non_neg_integer(),
          step_count: non_neg_integer()
        }
end
