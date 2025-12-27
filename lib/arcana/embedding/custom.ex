defmodule Arcana.Embedding.Custom do
  @moduledoc """
  Custom embedding provider using user-provided functions.

  Allows users to provide their own embedding function for maximum flexibility.

  ## Configuration

      # Arity-1 function (text -> embedding)
      config :arcana, embedding: {:custom, fn text -> YourModule.embed(text) end}

      # With explicit dimensions
      config :arcana, embedding: {:custom, fn text -> YourModule.embed(text) end, dimensions: 768}

  ## Requirements

  The function must:
  - Accept a single text string
  - Return `{:ok, [float()]}` or `{:error, term()}`

  """

  defstruct [:fun, :dimensions]

  @doc """
  Creates a new Custom embedder.

  ## Options

    * `:fun` - Required. Embedding function `(String.t() -> {:ok, [float()]} | {:error, term()})`
    * `:dimensions` - Optional. If not provided, will be auto-detected.

  """
  def new(opts) do
    fun = Keyword.fetch!(opts, :fun)

    unless is_function(fun, 1) do
      raise ArgumentError, "expected :fun to be a function with arity 1, got: #{inspect(fun)}"
    end

    %__MODULE__{
      fun: fun,
      dimensions: Keyword.get(opts, :dimensions)
    }
  end

  @doc """
  Detects the embedding dimensions by running a test embedding.
  """
  def detect_dimensions(%__MODULE__{} = embedder) do
    case do_embed(embedder, "test") do
      {:ok, embedding} -> {:ok, length(embedding)}
      error -> error
    end
  end

  @doc false
  def do_embed(%__MODULE__{fun: fun}, text) do
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

  defimpl Arcana.Embedding do
    def embed(embedder, text) do
      Arcana.Embedding.Custom.do_embed(embedder, text)
    end

    def embed_batch(embedder, texts) do
      results = Enum.map(texts, fn text -> Arcana.Embedding.Custom.do_embed(embedder, text) end)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(results, fn {:ok, emb} -> emb end)}
      else
        {:error, :batch_failed}
      end
    end

    def dimensions(%{dimensions: dims}) when is_integer(dims), do: dims

    def dimensions(embedder) do
      case Arcana.Embedding.Custom.detect_dimensions(embedder) do
        {:ok, dims} -> dims
        _ -> raise "Could not detect dimensions from custom embedding function"
      end
    end
  end
end
