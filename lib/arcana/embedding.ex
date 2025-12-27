defprotocol Arcana.Embedding do
  @moduledoc """
  Protocol for embedding providers used by Arcana.

  Arcana accepts any embedding provider that implements this protocol.
  Built-in implementations are provided for:

  - Local Bumblebee models (e.g., `bge-small-en-v1.5`)
  - OpenAI embeddings via Req.LLM
  - Custom functions

  ## Configuration

  Configure your embedding provider in `config.exs`:

      # Default: Local Bumblebee with bge-small-en-v1.5 (384 dims)
      config :arcana, embedding: :local

      # Local with different HuggingFace model
      config :arcana, embedding: {:local, model: "BAAI/bge-large-en-v1.5"}

      # OpenAI via Req.LLM
      config :arcana, embedding: {:openai, model: "text-embedding-3-small"}

      # Custom function
      config :arcana, embedding: {:custom, fn text -> YourModule.embed(text) end}

  """

  @doc """
  Embed a single text, returns a list of floats.
  """
  @spec embed(t, String.t()) :: {:ok, [float()]} | {:error, term()}
  def embed(embedder, text)

  @doc """
  Embed multiple texts in batch.
  """
  @spec embed_batch(t, [String.t()]) :: {:ok, [[float()]]} | {:error, term()}
  def embed_batch(embedder, texts)

  @doc """
  Returns the embedding dimensions.
  """
  @spec dimensions(t) :: pos_integer()
  def dimensions(embedder)
end
