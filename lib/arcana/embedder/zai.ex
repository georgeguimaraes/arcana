defmodule Arcana.Embedder.Zai do
  @moduledoc """
  Z.ai embedding provider.

  Uses Z.ai's `embedding-3` model which produces configurable-dimension embeddings.
  Default is 1536 dimensions to match OpenAI's `text-embedding-3-small`.

  ## Configuration

      # Default Z.ai model (embedding-3, 1536 dims)
      config :arcana, embedding: :zai

      # With custom dimensions
      config :arcana, embedding: {:zai, dimensions: 1024}

      # With API key (otherwise uses ZAI_API_KEY env var)
      config :arcana, embedding: {:zai, api_key: "your-api-key"}

  ## Requirements

  Requires the `ZAI_API_KEY` environment variable or `:api_key` option.
  """

  @behaviour Arcana.Embedder

  @default_model "embedding-3"
  @default_dimensions 1536
  @api_base "https://api.z.ai/api/paas/v4"

  @impl Arcana.Embedder
  def embed(text, opts) do
    api_key = get_api_key(opts)
    model = Keyword.get(opts, :model, @default_model)
    dims = Keyword.get(opts, :dimensions, @default_dimensions)

    start_metadata = %{text: text, model: model, dimensions: dims}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      result = call_api(text, model, dims, api_key)

      case result do
        {:ok, embedding} ->
          stop_metadata = %{dimensions: length(embedding)}
          {{:ok, embedding}, stop_metadata}

        {:error, reason} ->
          {{:error, reason}, %{}}
      end
    end)
  end

  @impl Arcana.Embedder
  def embed_batch(texts, opts) do
    api_key = get_api_key(opts)
    model = Keyword.get(opts, :model, @default_model)
    dims = Keyword.get(opts, :dimensions, @default_dimensions)

    start_metadata = %{count: length(texts), model: model, dimensions: dims}

    :telemetry.span([:arcana, :embed_batch], start_metadata, fn ->
      result = call_api(texts, model, dims, api_key)

      case result do
        {:ok, embeddings} ->
          stop_metadata = %{count: length(embeddings)}
          {{:ok, embeddings}, stop_metadata}

        {:error, reason} ->
          {{:error, reason}, %{}}
      end
    end)
  end

  @impl Arcana.Embedder
  def dimensions(opts) do
    Keyword.get(opts, :dimensions, @default_dimensions)
  end

  defp get_api_key(opts) do
    case Keyword.get(opts, :api_key) do
      nil ->
        System.get_env("ZAI_API_KEY") ||
          raise "ZAI_API_KEY not set. Set the environment variable or pass :api_key option."

      key ->
        key
    end
  end

  defp call_api(input, model, dimensions, api_key) do
    body = %{
      model: model,
      input: input,
      dimensions: dimensions
    }

    request =
      Req.new(
        url: "#{@api_base}/embeddings",
        method: :post,
        json: body,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ]
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        extract_embeddings(body, input)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "Z.ai API error (#{status}): #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Z.ai API request failed: #{inspect(reason)}"}
    end
  end

  defp extract_embeddings(%{"data" => data}, input) when is_binary(input) do
    case data do
      [%{"embedding" => embedding}] -> {:ok, embedding}
      _ -> {:error, "Unexpected response format"}
    end
  end

  defp extract_embeddings(%{"data" => data}, inputs) when is_list(inputs) do
    embeddings =
      data
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(& &1["embedding"])

    {:ok, embeddings}
  end

  defp extract_embeddings(body, _input) do
    {:error, "Unexpected response format: #{inspect(body)}"}
  end
end
