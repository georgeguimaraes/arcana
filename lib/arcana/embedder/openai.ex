defmodule Arcana.Embedder.OpenAI do
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

  @behaviour Arcana.Embedder

  @default_model "text-embedding-3-small"

  @impl Arcana.Embedder
  def embed(text, opts) do
    unless Code.ensure_loaded?(ReqLLM) do
      raise """
      ReqLLM is required for OpenAI embeddings but is not available.

      Add {:req_llm, "~> 0.3"} to your dependencies in mix.exs.
      """
    end

    model = Keyword.get(opts, :model, @default_model)
    model_spec = "openai:#{model}"

    start_metadata = %{text: text, model: model}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      # Use apply/3 to avoid compile-time warning about optional dependency
      case apply(ReqLLM, :embed, [model_spec, text]) do
        {:ok, embedding} ->
          stop_metadata = %{dimensions: length(embedding)}
          {{:ok, embedding}, stop_metadata}

        {:error, reason} ->
          {{:error, reason}, %{}}
      end
    end)
  end

  @impl Arcana.Embedder
  def dimensions(opts) do
    model = Keyword.get(opts, :model, @default_model)

    case model do
      "text-embedding-3-small" -> 1536
      "text-embedding-3-large" -> 3072
      "text-embedding-ada-002" -> 1536
      _ -> detect_dimensions(opts)
    end
  end

  defp detect_dimensions(opts) do
    case embed("test", opts) do
      {:ok, embedding} -> length(embedding)
      _ -> raise "Could not detect dimensions for OpenAI model"
    end
  end
end
