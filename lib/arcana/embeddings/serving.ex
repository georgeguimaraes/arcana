defmodule Arcana.Embeddings.Serving do
  @moduledoc """
  Nx.Serving for text embeddings using Bumblebee.

  Uses BAAI/bge-small-en-v1.5 which produces 384-dimensional embeddings.
  """

  @model_id "BAAI/bge-small-en-v1.5"

  @doc """
  Returns the child spec for starting the embedding serving.
  Add this to your application's supervision tree.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker
    }
  end

  def start_link(_opts) do
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_id})

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    Nx.Serving.start_link(serving: serving, name: __MODULE__, batch_timeout: 100)
  end

  @doc """
  Embeds a single text and returns a list of floats (384 dimensions).
  """
  def embed(text) when is_binary(text) do
    %{embedding: embedding} = Nx.Serving.batched_run(__MODULE__, text)
    Nx.to_flat_list(embedding)
  end

  @doc """
  Embeds multiple texts and returns a list of embeddings.
  """
  def embed_batch(texts) when is_list(texts) do
    Enum.map(texts, &embed/1)
  end
end
