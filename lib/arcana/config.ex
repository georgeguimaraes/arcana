defmodule Arcana.Config do
  @moduledoc """
  Configuration management for Arcana.

  Handles parsing and resolving configuration for embedders, chunkers,
  and other pluggable components.

  ## Redacting Sensitive Values

  Use `Arcana.Config.redact/1` to wrap any config value for safe inspection:

      config = Application.get_env(:arcana, :llm)
      inspect(Arcana.Config.redact(config))
      # => {"zai:glm-4.7", [api_key: "[REDACTED]"]}

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

  ## PDF Parser Configuration

      # Default: poppler's pdftotext
      config :arcana, pdf_parser: :poppler

      # Custom module implementing Arcana.FileParser.PDF behaviour
      config :arcana, pdf_parser: MyApp.PDFParser
      config :arcana, pdf_parser: {MyApp.PDFParser, some_option: "value"}

  ## Search Defaults

  Set defaults for `Arcana.search/2`. Per-call options override these.
  Any option accepted by `Arcana.Search.search/2` can be set globally.

      config :arcana, search: [
        limit: 10,
        threshold: 0.0,
        mode: :semantic,            # :semantic | :fulltext | :hybrid
        semantic_weight: 0.5,       # for hybrid mode
        fulltext_weight: 0.5,       # for hybrid mode
        rewriter: &MyApp.rewrite/1, # query rewriter function
        # plus any backend-specific opts (e.g. :hnsw_ef_search for pgvector)
      ]

  ## Ask Defaults

  Set defaults for `Arcana.ask/2`. Per-call options override these.
  Any option accepted by `Arcana.Ask.ask/2` can be set globally.

      config :arcana, ask: [
        limit: 5,
        mode: :semantic,
        threshold: 0.0,
        prompt: &MyApp.custom_prompt/3
      ]

  ## Reranker Configuration

  Set a global reranker that will be applied automatically by `Arcana.search/2`
  and `Arcana.ask/2`. Per-call `:reranker` options override this. Pass
  `reranker: false` per-call to disable for a single request.

      # Global reranker module
      config :arcana, reranker: Arcana.Agent.Reranker.CrossEncoder

      # With options (e.g. over_fetch multiplier, threshold)
      config :arcana, reranker: {Arcana.Agent.Reranker.CrossEncoder, over_fetch: 3}

      # Custom function: fn question, chunks, opts -> {:ok, reranked} end
      config :arcana, reranker: &MyApp.rerank/3

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
  Returns the configured PDF parser as a `{module, opts}` tuple.
  """
  def pdf_parser do
    Application.get_env(:arcana, :pdf_parser, :poppler)
    |> parse_pdf_parser_config()
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
  def graph_enabled?(opts) do
    case Keyword.get(opts, :graph) do
      nil -> Arcana.Graph.enabled?()
      value -> value
    end
  end

  @doc """
  Returns the value for `key` from opts, falling back to the global app env.

  Used to thread configuration like `:repo` and `:llm` from per-call opts
  with a fallback to `config :arcana, key: value`.

  ## Examples

      repo = Arcana.Config.get(opts, :repo)
      llm = Arcana.Config.get(opts, :llm)

  """
  def get(opts, key) do
    opts[key] || Application.get_env(:arcana, key)
  end

  @doc """
  Merges global keyword-list config under `app_key` with per-call opts.

  Per-call opts override the global config. Used to thread namespace
  configs like `:search`, `:ask`, and `:graph`.

  ## Examples

      # Reads `config :arcana, search: [limit: 10]` and merges
      opts = Arcana.Config.merge_app_opts(opts, :search)

      # Reads `config :arcana, ask: [limit: 5]` and merges
      opts = Arcana.Config.merge_app_opts(opts, :ask)

  """
  def merge_app_opts(opts, app_key) do
    Application.get_env(:arcana, app_key, [])
    |> Keyword.merge(opts)
  end

  @doc """
  Returns the configured reranker, resolving per-call opts and global config.

  Returns `nil` if no reranker is set or if explicitly disabled with
  `reranker: false`. Otherwise returns `{module_or_fun, opts}`.
  """
  def reranker(opts \\ []) do
    case Keyword.fetch(opts, :reranker) do
      {:ok, value} -> parse_reranker_config(value)
      :error -> Application.get_env(:arcana, :reranker) |> parse_reranker_config()
    end
  end

  # Generic pluggable component parser.
  #
  # All `parse_*_config` functions delegate to this. Each component has a
  # spec describing its shortcuts, custom function arity (if any), and
  # whether nil/false should be allowed (for optional components like
  # reranker).
  defp parse_pluggable(value, spec) do
    shortcuts = spec[:shortcuts] || %{}
    custom_arity = spec[:custom_arity]
    custom_module = spec[:custom_module]
    name = spec[:name] || "component"
    allow_nil? = spec[:allow_nil?] || false

    cond do
      is_nil(value) and allow_nil? ->
        nil

      value == false and allow_nil? ->
        nil

      is_atom(value) and Map.has_key?(shortcuts, value) ->
        {Map.fetch!(shortcuts, value), []}

      is_tuple(value) and tuple_size(value) == 2 and is_atom(elem(value, 0)) and
        is_list(elem(value, 1)) and Map.has_key?(shortcuts, elem(value, 0)) ->
        {Map.fetch!(shortcuts, elem(value, 0)), elem(value, 1)}

      custom_arity && is_function(value, custom_arity) ->
        if custom_module, do: {custom_module, [fun: value]}, else: {value, []}

      is_atom(value) and not is_nil(value) ->
        {value, []}

      is_tuple(value) and tuple_size(value) == 2 and is_atom(elem(value, 0)) and
          is_list(elem(value, 1)) ->
        value

      true ->
        raise ArgumentError, "invalid #{name} config: #{inspect(value)}"
    end
  end

  @doc false
  def parse_reranker_config(value) do
    parse_pluggable(value,
      name: "reranker",
      custom_arity: 3,
      allow_nil?: true
    )
  end

  @doc false
  def parse_embedder_config(value) do
    parse_pluggable(value,
      name: "embedding",
      shortcuts: %{
        local: Arcana.Embedder.Local,
        openai: Arcana.Embedder.OpenAI
      },
      custom_arity: 1,
      custom_module: Arcana.Embedder.Custom
    )
  end

  @doc false
  def parse_chunker_config(value) do
    parse_pluggable(value,
      name: "chunker",
      shortcuts: %{default: Arcana.Chunker.Default},
      custom_arity: 2,
      custom_module: Arcana.Chunker.Custom
    )
  end

  @doc false
  def parse_pdf_parser_config(value) do
    parse_pluggable(value,
      name: "pdf_parser",
      shortcuts: %{poppler: Arcana.FileParser.PDF.Poppler}
    )
  end

  @doc false
  def parse_entity_matcher_config(value) do
    parse_pluggable(value,
      name: "entity_matcher",
      shortcuts: %{
        embedding: Arcana.Graph.EntityMatcher.Embedding,
        ner: Arcana.Graph.EntityMatcher.NER
      }
    )
  end

  # Redaction support

  @sensitive_keys [:api_key, :api_secret, :secret_key, :access_key, :token, :password, :secret]

  @doc """
  Wraps a config value for safe inspection with sensitive data redacted.

  Returns a struct that implements the `Inspect` protocol and automatically
  redacts sensitive keys like `:api_key`, `:token`, `:password`, etc.

  ## Example

      iex> config = {"zai:glm-4.7", [api_key: "secret123"]}
      iex> inspect(Arcana.Config.redact(config))
      ~s|{"zai:glm-4.7", [api_key: "[REDACTED]"]}|

  """
  def redact(value) do
    %Arcana.Config.Redacted{value: do_redact(value)}
  end

  @doc false
  def do_redact(nil), do: nil
  def do_redact(val) when is_atom(val), do: val
  def do_redact(val) when is_binary(val), do: val
  def do_redact(val) when is_number(val), do: val
  def do_redact(fun) when is_function(fun), do: "#Function<...>"

  def do_redact(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      for {k, v} <- opts do
        if k in @sensitive_keys, do: {k, "[REDACTED]"}, else: {k, do_redact(v)}
      end
    else
      Enum.map(opts, &do_redact/1)
    end
  end

  def do_redact(%{} = map) do
    for {k, v} <- map, into: %{} do
      if k in @sensitive_keys, do: {k, "[REDACTED]"}, else: {k, do_redact(v)}
    end
  end

  def do_redact({a, b}), do: {do_redact(a), do_redact(b)}
  def do_redact({a, b, c}), do: {do_redact(a), do_redact(b), do_redact(c)}
  def do_redact(other), do: other
end
