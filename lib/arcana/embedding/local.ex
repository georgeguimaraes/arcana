defmodule Arcana.Embedding.Local do
  @moduledoc """
  Local embedding provider using Bumblebee and Nx.Serving.

  Uses HuggingFace models locally. Default is `BAAI/bge-small-en-v1.5` (384 dimensions).

  ## Configuration

      # Default model
      config :arcana, embedding: :local

      # Custom HuggingFace model
      config :arcana, embedding: {:local, model: "BAAI/bge-large-en-v1.5"}

  """

  defstruct [:model, :dimensions, :serving_name]

  @default_model "BAAI/bge-small-en-v1.5"

  @doc """
  Creates a new Local embedder.

  ## Options

    * `:model` - HuggingFace model ID (default: "BAAI/bge-small-en-v1.5")

  """
  def new(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    serving_name = Module.concat(__MODULE__, String.to_atom(model))

    %__MODULE__{
      model: model,
      serving_name: serving_name,
      dimensions: nil
    }
  end

  @doc """
  Returns the child spec for starting the embedding serving.
  Add this to your application's supervision tree.
  """
  def child_spec(embedder) do
    %{
      id: embedder.serving_name,
      start: {__MODULE__, :start_link, [embedder]},
      type: :worker
    }
  end

  @doc """
  Starts the Nx.Serving for this embedder.
  """
  def start_link(%__MODULE__{} = embedder) do
    {:ok, model_info} = Bumblebee.load_model({:hf, embedder.model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, embedder.model})

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.start_link(serving: serving, name: embedder.serving_name, batch_timeout: 100)
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
  def do_embed(%__MODULE__{serving_name: name}, text) do
    start_metadata = %{text: text}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      %{embedding: embedding} = Nx.Serving.batched_run(name, text)
      result = Nx.to_flat_list(embedding)

      stop_metadata = %{dimensions: length(result)}

      {{:ok, result}, stop_metadata}
    end)
  end

  defimpl Arcana.Embedding do
    def embed(embedder, text) do
      Arcana.Embedding.Local.do_embed(embedder, text)
    end

    def embed_batch(embedder, texts) do
      results = Enum.map(texts, fn text -> Arcana.Embedding.Local.do_embed(embedder, text) end)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(results, fn {:ok, emb} -> emb end)}
      else
        {:error, :batch_failed}
      end
    end

    def dimensions(%{dimensions: dims}) when is_integer(dims), do: dims

    def dimensions(embedder) do
      case Arcana.Embedding.Local.detect_dimensions(embedder) do
        {:ok, dims} -> dims
        _ -> raise "Could not detect dimensions for #{embedder.model}"
      end
    end
  end
end
