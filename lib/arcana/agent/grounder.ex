defmodule Arcana.Agent.Grounder do
  @moduledoc """
  Behaviour for grounding analysis on LLM-generated answers.

  Grounders detect hallucinations by checking whether the answer is
  supported by the retrieved context chunks.

  ## Built-in Implementations

  - `Arcana.Agent.Grounder.Lettuce` - Uses LettuceDetect (ModernBERT-based token classifier) via ONNX Runtime (default)

  ## Custom Implementations

  Implement the `ground/3` callback:

      defmodule MyApp.CustomGrounder do
        @behaviour Arcana.Agent.Grounder

        @impl Arcana.Agent.Grounder
        def ground(answer, chunks, opts) do
          # Your custom grounding logic
          {:ok, %Arcana.Grounding.Result{score: 1.0, hallucinated_spans: []}}
        end
      end

  Or provide a function directly:

      Agent.ground(ctx, grounder: fn answer, chunks, opts ->
        {:ok, %Arcana.Grounding.Result{score: 1.0, hallucinated_spans: []}}
      end)
  """

  @doc """
  Analyzes whether the answer is grounded in the provided context chunks.

  ## Parameters

  - `answer` - The LLM-generated answer to check
  - `chunks` - The context chunks used to generate the answer
  - `opts` - Options, including `:question` (the original question)

  ## Returns

  - `{:ok, %Arcana.Grounding.Result{}}` - Grounding analysis result
  - `{:error, reason}` - On failure
  """
  @callback ground(
              answer :: String.t(),
              chunks :: [map()],
              opts :: keyword()
            ) :: {:ok, Arcana.Grounding.Result.t()} | {:error, term()}
end
