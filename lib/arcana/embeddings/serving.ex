defmodule Arcana.Embeddings.Serving do
  @moduledoc """
  Nx.Serving for text embeddings using Bumblebee.

  Uses BAAI/bge-small-en-v1.5 which produces 384-dimensional embeddings by default.
  """

  alias Bumblebee.Text.TextEmbedding

  @default_model "BAAI/bge-small-en-v1.5"

  @doc """
  Returns the child spec for starting the embedding serving.
  Add this to your application's supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    tokenizer_model = Keyword.get(opts, :tokenizer, model)

    model_opts =
      opts
      |> Keyword.take([:module, :architecture])
      |> Enum.into([])

    {:ok, model_info} = Bumblebee.load_model({:hf, model}, model_opts)
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, tokenizer_model})

    # Get defn_options from Nx config (includes compiler like EXLA or EMLX)
    defn_options = Nx.Defn.default_options()

    serving =
      TextEmbedding.text_embedding(model_info, tokenizer,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: defn_options
      )

    Nx.Serving.start_link(serving: serving, name: __MODULE__, batch_timeout: 100)
  end

  @doc """
  Embeds a single text and returns a list of floats (384 dimensions).
  """
  def embed(text) when is_binary(text) do
    start_metadata = %{text: text}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      %{embedding: embedding} = Nx.Serving.batched_run(__MODULE__, text)
      result = Nx.to_flat_list(embedding)

      stop_metadata = %{dimensions: length(result)}

      {result, stop_metadata}
    end)
  end

  @doc """
  Embeds multiple texts and returns a list of embeddings.
  """
  def embed_batch(texts) when is_list(texts) do
    Enum.map(texts, &embed/1)
  end
end
