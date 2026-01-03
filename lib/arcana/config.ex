defmodule Arcana.Config do
  @moduledoc """
  Configuration management for Arcana.

  Handles parsing and resolving configuration for embedders, chunkers,
  and other pluggable components.

  ## Embedder Configuration

      # Default: Local Bumblebee with bge-small-en-v1.5
      config :arcana, embedder: :local

      # Local with different model
      config :arcana, embedder: {:local, model: "BAAI/bge-large-en-v1.5"}

      # OpenAI (requires req_llm and OPENAI_API_KEY)
      config :arcana, embedder: :openai
      config :arcana, embedder: {:openai, model: "text-embedding-3-large"}

      # Custom function
      config :arcana, embedder: fn text -> {:ok, embedding} end

      # Custom module implementing Arcana.Embedder behaviour
      config :arcana, embedder: MyApp.CohereEmbedder
      config :arcana, embedder: {MyApp.CohereEmbedder, api_key: "..."}

  ## Chunker Configuration

      # Default: text_chunker-based chunking
      config :arcana, chunker: :default

      # Default chunker with custom options
      config :arcana, chunker: {:default, chunk_size: 512, chunk_overlap: 100}

      # Custom function (receives text, opts; returns list of chunk maps)
      config :arcana, chunker: fn text, _opts ->
        [%{text: text, chunk_index: 0, token_count: 10}]
      end

      # Custom module implementing Arcana.Chunker behaviour
      config :arcana, chunker: MyApp.SemanticChunker
      config :arcana, chunker: {MyApp.SemanticChunker, model: "..."}

  """

  @doc """
  Returns the configured embedder as a `{module, opts}` tuple.
  """
  def embedder do
    Application.get_env(:arcana, :embedder, :local)
    |> parse_embedder_config()
  end

  @doc """
  Returns the configured chunker as a `{module, opts}` tuple.
  """
  def chunker do
    Application.get_env(:arcana, :chunker, :default)
    |> parse_chunker_config()
  end

  @doc """
  Resolves chunker from options, falling back to global config.
  """
  def resolve_chunker(opts) do
    case Keyword.fetch(opts, :chunker) do
      {:ok, config} -> parse_chunker_config(config)
      :error -> chunker()
    end
  end

  @doc """
  Returns the current Arcana configuration.

  Useful for logging, debugging, and storing with evaluation runs
  to track which settings produced which results.

  ## Example

      Arcana.Config.current()
      # => %{
      #   embedding: %{module: Arcana.Embedder.Local, model: "BAAI/bge-small-en-v1.5", dimensions: 384},
      #   vector_store: :pgvector
      # }

  """
  def current do
    {emb_module, emb_opts} = embedder()
    model = Keyword.get(emb_opts, :model, "BAAI/bge-small-en-v1.5")

    %{
      embedding: %{
        module: emb_module,
        model: model,
        dimensions: Arcana.Embedder.dimensions(embedder())
      },
      vector_store: Application.get_env(:arcana, :vector_store, :pgvector),
      reranker: Application.get_env(:arcana, :reranker, Arcana.Reranker.LLM),
      graph: Arcana.Graph.config()
    }
  end

  @doc """
  Returns whether GraphRAG is enabled globally or for specific options.

  Checks the `:graph` option in the provided opts first, then falls back
  to the global configuration.

  ## Examples

      # Check global config
      Arcana.Config.graph_enabled?([])

      # Override with per-call option
      Arcana.Config.graph_enabled?(graph: true)

  """
  @spec graph_enabled?(keyword()) :: boolean()
  def graph_enabled?(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Arcana.Graph.enabled?()
      value -> value
    end
  end

  # Embedder config parsing

  defp parse_embedder_config(:local), do: {Arcana.Embedder.Local, []}
  defp parse_embedder_config({:local, opts}), do: {Arcana.Embedder.Local, opts}
  defp parse_embedder_config(:openai), do: {Arcana.Embedder.OpenAI, []}
  defp parse_embedder_config({:openai, opts}), do: {Arcana.Embedder.OpenAI, opts}

  defp parse_embedder_config(fun) when is_function(fun, 1),
    do: {Arcana.Embedder.Custom, [fun: fun]}

  defp parse_embedder_config({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp parse_embedder_config(module) when is_atom(module), do: {module, []}

  defp parse_embedder_config(other) do
    raise ArgumentError, "invalid embedding config: #{inspect(other)}"
  end

  # Chunker config parsing

  defp parse_chunker_config(:default), do: {Arcana.Chunker.Default, []}
  defp parse_chunker_config({:default, opts}), do: {Arcana.Chunker.Default, opts}

  defp parse_chunker_config(fun) when is_function(fun, 2),
    do: {Arcana.Chunker.Custom, [fun: fun]}

  defp parse_chunker_config({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp parse_chunker_config(module) when is_atom(module), do: {module, []}

  defp parse_chunker_config(other) do
    raise ArgumentError, "invalid chunker config: #{inspect(other)}"
  end
end
