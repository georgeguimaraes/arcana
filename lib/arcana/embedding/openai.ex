defmodule Arcana.Embedding.OpenAI do
  @moduledoc """
  OpenAI embedding provider using Req.LLM.

  Uses OpenAI's embedding models via Req.LLM. Default is `text-embedding-3-small` (1536 dimensions).

  ## Configuration

      # Default OpenAI model
      config :arcana, embedding: :openai

      # Custom OpenAI model
      config :arcana, embedding: {:openai, model: "text-embedding-3-large"}

  ## Requirements

  Requires the `req_llm` dependency and `OPENAI_API_KEY` environment variable.
  """

  defstruct [:model, :dimensions]

  @default_model "text-embedding-3-small"

  @doc """
  Creates a new OpenAI embedder.

  ## Options

    * `:model` - OpenAI embedding model (default: "text-embedding-3-small")

  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    %__MODULE__{
      model: model,
      dimensions: nil
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
  def do_embed(%__MODULE__{model: model}, text) do
    model_spec = "openai:#{model}"
    start_metadata = %{text: text, model: model}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      case ReqLLM.embed(model_spec, text) do
        {:ok, embedding} ->
          stop_metadata = %{dimensions: length(embedding)}
          {{:ok, embedding}, stop_metadata}

        {:error, reason} ->
          {{:error, reason}, %{}}
      end
    end)
  end

  @doc false
  def do_embed_batch(%__MODULE__{} = embedder, texts) do
    start_metadata = %{count: length(texts), model: embedder.model}

    :telemetry.span([:arcana, :embed_batch], start_metadata, fn ->
      results = Enum.map(texts, fn text -> do_embed(embedder, text) end)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        embeddings = Enum.map(results, fn {:ok, emb} -> emb end)
        stop_metadata = %{count: length(embeddings)}
        {{:ok, embeddings}, stop_metadata}
      else
        {{:error, :batch_failed}, %{}}
      end
    end)
  end

  if Code.ensure_loaded?(ReqLLM) do
    defimpl Arcana.Embedding do
      def embed(embedder, text) do
        Arcana.Embedding.OpenAI.do_embed(embedder, text)
      end

      def embed_batch(embedder, texts) do
        Arcana.Embedding.OpenAI.do_embed_batch(embedder, texts)
      end

      def dimensions(%{dimensions: dims}) when is_integer(dims), do: dims

      def dimensions(embedder) do
        case Arcana.Embedding.OpenAI.detect_dimensions(embedder) do
          {:ok, dims} -> dims
          _ -> raise "Could not detect dimensions for openai:#{embedder.model}"
        end
      end
    end
  end
end
