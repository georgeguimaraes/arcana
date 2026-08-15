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
        mode: :vector,              # :vector | :keyword | :hybrid
        vector_weight: 0.5,         # for hybrid mode
        keyword_weight: 0.5,        # for hybrid mode
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
      config :arcana, reranker: Arcana.Reranker.CrossEncoder

      # With options (e.g. over_fetch multiplier, threshold)
      config :arcana, reranker: {Arcana.Reranker.CrossEncoder, over_fetch: 3}

      # Custom function: fn question, chunks, opts -> {:ok, reranked} end
      config :arcana, reranker: &MyApp.rerank/3

  """

  @reader_key {__MODULE__, :env_reader}

  @doc """
  Returns the value for `key` from the `:arcana` app env.

  All runtime configuration reads in Arcana go through this function. Test
  suites can install a custom reader with `install_env_reader/1` to shadow
  keys per-process instead of mutating global state.
  """
  def get_env(key, default \\ nil) do
    case :persistent_term.get(@reader_key, nil) do
      nil -> Application.get_env(:arcana, key, default)
      reader -> reader.(key, default)
    end
  end

  @doc false
  def install_env_reader(reader) when is_function(reader, 2) do
    :persistent_term.put(@reader_key, reader)
  end

  @doc """
  Returns the configured embedder as a `{module, opts}` tuple.
  """
  def embedder do
    get_env(:embedder, :local)
    |> parse_embedder_config()
  end

  @doc """
  Resolves embedder from options, falling back to global config.
  """
  def resolve_embedder(opts) do
    case Keyword.fetch(opts, :embedder) do
      {:ok, config} -> parse_embedder_config(config)
      :error -> embedder()
    end
  end

  @doc """
  Returns the configured chunker as a `{module, opts}` tuple.
  """
  def chunker do
    get_env(:chunker, :default)
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
    get_env(:pdf_parser, :poppler)
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
      vector_store: get_env(:vector_store, :pgvector),
      reranker: get_env(:reranker, Arcana.Reranker.LLM),
      strict_collections: get_env(:strict_collections, false),
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
  Returns whether strict collection scoping is enabled.

  When strict, an unknown collection name is an error
  (`{:error, {:unknown_collection, name}}`) instead of silently widening
  the operation to every collection. Checks the `:strict_collections`
  option in the provided opts first (so `strict_collections: false` can
  override a global `true` per call), then falls back to
  `config :arcana, strict_collections: true`. Defaults to `false`; the
  default will flip to `true` in Arcana 3.0.
  """
  def strict_collections?(opts \\ []) do
    case Keyword.get(opts, :strict_collections) do
      nil -> get_env(:strict_collections, false)
      value -> value
    end
  end

  @doc """
  Returns the repo from opts or the global config, raising when neither
  is set.
  """
  def require_repo!(opts) do
    opts[:repo] || get_env(:repo) ||
      raise ArgumentError, "repo is required"
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
    opts[key] || get_env(key)
  end

  @repo_unset :__arcana_repo_unset__

  @repo_config_shapes """
  Configure the repo with:

      config :arcana, repo: MyApp.Repo

  or with the per-repo shape:

      config :arcana, MyApp.Repo, priv: "priv/my_repo"
  """

  @doc """
  Resolves the Ecto repo configured for Arcana's mix tasks.

  Accepts either configuration shape:

      # Explicit repo key
      config :arcana, repo: MyApp.Repo

      # Per-repo configuration (e.g. custom priv directory)
      config :arcana, MyApp.Repo, priv: "priv/my_repo"

  When only the per-repo shape is present and exactly one repo is
  configured, that repo is used (with a note printed to stderr). Raises
  `ArgumentError` when no repo can be resolved, or when several per-repo
  entries exist without an explicit `:repo` key to disambiguate.

  `repo: nil` means "not set" and falls through to the per-repo scan.
  `repo: false` is an explicit "no repo", so it raises the same "no Ecto
  repo configured" error instead of quietly picking a per-repo entry.

  Called without arguments, the `:repo` key is read through `get_env/2` so
  process-scoped overrides installed via `install_env_reader/1` are honored.
  Pass an explicit env keyword list to resolve against it directly.
  """
  def repo!(env \\ nil)

  def repo!(nil) do
    # The `:repo` read goes through get_env/2 so test overrides shadow it.
    # A sentinel default separates "unset" from a configured `nil`/`false`.
    # The per-repo fallback has to enumerate keys, which the reader seam
    # can't express (it resolves one key at a time), so it reads the raw
    # app env.
    case get_env(:repo, @repo_unset) do
      false -> raise_repo_disabled()
      repo when repo in [@repo_unset, nil] -> repo_from_module_keys(all_env())
      repo -> repo
    end
  end

  def repo!(env) when is_list(env) do
    case Keyword.fetch(env, :repo) do
      {:ok, false} -> raise_repo_disabled()
      {:ok, nil} -> repo_from_module_keys(env)
      {:ok, repo} -> repo
      :error -> repo_from_module_keys(env)
    end
  end

  defp all_env, do: Application.get_all_env(:arcana)

  defp raise_repo_disabled do
    raise ArgumentError,
          "no Ecto repo configured for :arcana: `repo: false` disables repo " <>
            "resolution.\n\n" <> @repo_config_shapes
  end

  defp repo_from_module_keys(env) do
    env
    |> Keyword.keys()
    |> Enum.filter(&ecto_repo_key?/1)
    |> case do
      [repo] ->
        IO.puts(
          :stderr,
          "Arcana: using #{inspect(repo)} from `config :arcana, #{inspect(repo)}, ...`. " <>
            "Set `config :arcana, repo: #{inspect(repo)}` to make this explicit."
        )

        repo

      [] ->
        raise ArgumentError, "no Ecto repo configured for :arcana.\n\n" <> @repo_config_shapes

      repos ->
        raise ArgumentError,
              "several Ecto repos configured for :arcana " <>
                "(#{Enum.map_join(repos, ", ", &inspect/1)}) and no `:repo` key to " <>
                "disambiguate.\n\n" <> @repo_config_shapes
    end
  end

  defp ecto_repo_key?(key) do
    is_atom(key) and String.starts_with?(Atom.to_string(key), "Elixir.") and
      Code.ensure_loaded?(key) and function_exported?(key, :__adapter__, 0)
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
    get_env(app_key, [])
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
      :error -> get_env(:reranker) |> parse_reranker_config()
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
      nil_or_false?(value, allow_nil?) -> nil
      shortcut_atom?(value, shortcuts) -> {Map.fetch!(shortcuts, value), []}
      shortcut_tuple?(value, shortcuts) -> shortcut_tuple_result(value, shortcuts)
      custom_function?(value, custom_arity) -> custom_function_result(value, custom_module)
      plain_module?(value) -> {value, []}
      module_opts_tuple?(value) -> value
      true -> raise ArgumentError, "invalid #{name} config: #{inspect(value)}"
    end
  end

  defp nil_or_false?(nil, true), do: true
  defp nil_or_false?(false, true), do: true
  defp nil_or_false?(_, _), do: false

  defp shortcut_atom?(value, shortcuts) when is_atom(value),
    do: Map.has_key?(shortcuts, value)

  defp shortcut_atom?(_, _), do: false

  defp shortcut_tuple?(value, shortcuts) do
    module_opts_tuple?(value) and Map.has_key?(shortcuts, elem(value, 0))
  end

  defp shortcut_tuple_result({module, opts}, shortcuts),
    do: {Map.fetch!(shortcuts, module), opts}

  defp custom_function?(_value, nil), do: false
  defp custom_function?(value, arity), do: is_function(value, arity)

  defp custom_function_result(fun, nil), do: {fun, []}
  defp custom_function_result(fun, module), do: {module, [fun: fun]}

  # `true`/`false` are atoms but never module names: letting them through
  # here produced `function false.parse/2` at call time instead of a
  # config error (or, for components that accept it, a disabled component).
  defp plain_module?(value), do: is_atom(value) and not is_boolean(value) and not is_nil(value)

  # The head has to pass the same test a bare module does: `{false, opts}`
  # and `{nil, opts}` look like a {module, opts} pair but land on
  # `function false.parse/2` at call time, exactly like bare `false` did.
  defp module_opts_tuple?(value) do
    is_tuple(value) and tuple_size(value) == 2 and
      plain_module?(elem(value, 0)) and is_list(elem(value, 1))
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

  @doc """
  Returns the configured file parsers as a map of extension to
  `{module, opts}`.

  Extensions are normalized to lowercase with a leading dot, so
  `%{"docx" => ...}` and `%{".DOCX" => ...}` both register `".docx"`.

      config :arcana, file_parsers: %{".docx" => {MyApp.DocxParser, []}}

  Mapping an extension to `false` disables it: nothing parses it, not the
  built-in route and not the `:fallback_parser`. Such entries come back
  as `nil`.

      config :arcana, file_parsers: %{".pdf" => false}

  """
  def file_parsers do
    get_env(:file_parsers, %{})
    |> Map.new(fn {extension, value} ->
      {normalize_extension(extension), parse_file_parser_config(value)}
    end)
  end

  @doc """
  Returns the configured fallback parser as `{module, opts}`, or `nil`.

  Consulted for any extension without a native or registered parser:

      config :arcana, fallback_parser: {MyApp.ExtractionService, []}

  `nil` and `false` both mean "no fallback".
  """
  def fallback_parser do
    get_env(:fallback_parser) |> parse_file_parser_config()
  end

  @doc false
  def parse_file_parser_config(value) do
    parse_pluggable(value, name: "file parser", allow_nil?: true)
  end

  @doc false
  def normalize_extension(extension) do
    extension = extension |> to_string() |> String.downcase()

    if String.starts_with?(extension, "."), do: extension, else: "." <> extension
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
