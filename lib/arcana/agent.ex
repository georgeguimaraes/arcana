defmodule Arcana.Agent do
  @moduledoc """
  Deprecated. Use `Arcana.Pipeline` instead.

  This module is a thin facade kept for backward compatibility. It will be
  removed in a future major version. All functions delegate to
  `Arcana.Pipeline` and emit compile-time deprecation warnings.

  ## Migration

      # Before
      Arcana.Agent.new(question)
      |> Arcana.Agent.search()
      |> Arcana.Agent.answer()

      # After
      Arcana.Pipeline.new(question)
      |> Arcana.Pipeline.search()
      |> Arcana.Pipeline.answer()

  Custom modules implementing the pipeline behaviours need to update
  their `@behaviour` declarations from `Arcana.Agent.*` to
  `Arcana.Pipeline.*`. The callbacks themselves are unchanged.
  """

  @deprecated "Use Arcana.Pipeline.new/2"
  defdelegate new(question, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.gate/2"
  defdelegate gate(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.rewrite/2"
  defdelegate rewrite(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.select/2"
  defdelegate select(ctx, opts), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.expand/2"
  defdelegate expand(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.decompose/2"
  defdelegate decompose(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.search/2"
  defdelegate search(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.reason/2"
  defdelegate reason(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.rerank/2"
  defdelegate rerank(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.answer/2"
  defdelegate answer(ctx, opts \\ []), to: Arcana.Pipeline

  @deprecated "Use Arcana.Pipeline.ground/2"
  defdelegate ground(ctx, opts \\ []), to: Arcana.Pipeline
end
