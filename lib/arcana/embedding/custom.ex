defmodule Arcana.Embedding.Custom do
  @moduledoc """
  Custom embedding provider using user-provided functions.

  This module wraps a user-provided function to implement the `Arcana.Embedding`
  behaviour. It's used internally when configuring a function as the embedder.

  ## Configuration

      # Function that returns {:ok, embedding}
      config :arcana, embedding: fn text -> {:ok, List.duplicate(0.1, 384)} end

  The function must:
  - Accept a single text string
  - Return `{:ok, [float()]}` or `{:error, term()}`

  """

  @behaviour Arcana.Embedding

  @impl Arcana.Embedding
  def embed(text, opts) do
    fun = Keyword.fetch!(opts, :fun)

    start_metadata = %{text: text}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      case fun.(text) do
        {:ok, embedding} when is_list(embedding) ->
          stop_metadata = %{dimensions: length(embedding)}
          {{:ok, embedding}, stop_metadata}

        {:error, reason} ->
          {{:error, reason}, %{}}

        other ->
          {{:error, {:unexpected_result, other}}, %{}}
      end
    end)
  end

  @impl Arcana.Embedding
  def dimensions(opts) do
    case Keyword.get(opts, :dimensions) do
      nil -> detect_dimensions(opts)
      dims -> dims
    end
  end

  defp detect_dimensions(opts) do
    case embed("test", opts) do
      {:ok, embedding} -> length(embedding)
      _ -> raise "Could not detect dimensions from custom embedding function"
    end
  end
end
