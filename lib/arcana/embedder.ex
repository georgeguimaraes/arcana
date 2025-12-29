defmodule Arcana.Embedder do
  @moduledoc """
  Behaviour for embedding providers used by Arcana.

  Arcana accepts any module that implements this behaviour.
  Built-in implementations are provided for:

  - `Arcana.Embedder.Local` - Local Bumblebee models (e.g., `bge-small-en-v1.5`)
  - `Arcana.Embedder.OpenAI` - OpenAI embeddings via Req.LLM
  - `Arcana.Embedder.Zai` - Z.ai embeddings (embedding-3 model)

  ## Configuration

  Configure your embedding provider in `config.exs`:

      # Default: Local Bumblebee with bge-small-en-v1.5 (384 dims)
      config :arcana, embedding: :local

      # Local with different HuggingFace model
      config :arcana, embedding: {:local, model: "BAAI/bge-large-en-v1.5"}

      # OpenAI via Req.LLM
      config :arcana, embedding: :openai
      config :arcana, embedding: {:openai, model: "text-embedding-3-large"}

      # Z.ai (1536 dims by default)
      config :arcana, embedding: :zai
      config :arcana, embedding: {:zai, dimensions: 1024}

      # Custom function
      config :arcana, embedding: fn text -> {:ok, embedding} end

      # Custom module implementing this behaviour
      config :arcana, embedding: MyApp.CohereEmbedder
      config :arcana, embedding: {MyApp.CohereEmbedder, api_key: "..."}

  ## Implementing a Custom Embedder

  Create a module that implements this behaviour:

      defmodule MyApp.CohereEmbedder do
        @behaviour Arcana.Embedder

        @impl true
        def embed(text, opts) do
          api_key = opts[:api_key] || System.get_env("COHERE_API_KEY")
          # Call Cohere API...
          {:ok, embedding}
        end

        @impl true
        def dimensions(_opts), do: 1024
      end

  Then configure:

      config :arcana, embedding: {MyApp.CohereEmbedder, api_key: "..."}

  """

  @doc """
  Embed a single text string.

  Returns `{:ok, embedding}` where embedding is a list of floats,
  or `{:error, reason}` on failure.
  """
  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, [float()]} | {:error, term()}

  @doc """
  Embed multiple texts in batch.

  Default implementation calls `embed/2` for each text sequentially.
  Override for providers that support native batch embedding.
  """
  @callback embed_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc """
  Returns the embedding dimensions.
  """
  @callback dimensions(opts :: keyword()) :: pos_integer()

  @optional_callbacks embed_batch: 2

  @doc """
  Embeds text using the configured embedder.

  The embedder is a `{module, opts}` tuple where module implements
  this behaviour.
  """
  def embed({module, opts}, text) when is_atom(module) do
    module.embed(text, opts)
  end

  @doc """
  Embeds multiple texts using the configured embedder.

  Falls back to sequential embedding if the module doesn't implement
  `embed_batch/2`.
  """
  def embed_batch({module, opts}, texts) when is_atom(module) do
    if function_exported?(module, :embed_batch, 2) do
      module.embed_batch(texts, opts)
    else
      # Default: sequential embedding
      results = Enum.map(texts, fn text -> module.embed(text, opts) end)

      if Enum.all?(results, &match?({:ok, _}, &1)) do
        {:ok, Enum.map(results, fn {:ok, emb} -> emb end)}
      else
        {:error, :batch_failed}
      end
    end
  end

  @doc """
  Returns the embedding dimensions for the configured embedder.
  """
  def dimensions({module, opts}) when is_atom(module) do
    module.dimensions(opts)
  end
end
