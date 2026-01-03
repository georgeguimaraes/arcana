defmodule Arcana.Embedder.Local do
  @moduledoc """
  Local embedding provider using Bumblebee and Nx.Serving.

  Uses HuggingFace models locally. Default is `BAAI/bge-small-en-v1.5` (384 dimensions).

  ## Configuration

      # Default model
      config :arcana, embedder: :local

      # Custom HuggingFace model
      config :arcana, embedder: {:local, model: "BAAI/bge-large-en-v1.5"}

  ## Starting the Serving

  Add `Arcana.Embedder.Local.child_spec/1` to your application supervision tree:

      children = [
        {Arcana.Embedder.Local, model: "BAAI/bge-small-en-v1.5"},
        # ... other children
      ]

  """

  @behaviour Arcana.Embedder

  alias Bumblebee.Text.TextEmbedding

  @default_model "BAAI/bge-small-en-v1.5"

  # Known dimensions for common embedding models
  @model_dimensions %{
    # BGE models (BAAI) - recommended default
    "BAAI/bge-small-en-v1.5" => 384,
    "BAAI/bge-base-en-v1.5" => 768,
    "BAAI/bge-large-en-v1.5" => 1024,
    # E5 models (Microsoft) - good alternative
    "intfloat/e5-small-v2" => 384,
    "intfloat/e5-base-v2" => 768,
    "intfloat/e5-large-v2" => 1024,
    # GTE models (Alibaba)
    "thenlper/gte-small" => 384,
    "thenlper/gte-base" => 768,
    "thenlper/gte-large" => 1024,
    # Sentence Transformers - lightweight option
    "sentence-transformers/all-MiniLM-L6-v2" => 384
  }

  # E5 models require special prefixes for queries vs documents
  @e5_models MapSet.new([
               "intfloat/e5-small-v2",
               "intfloat/e5-base-v2",
               "intfloat/e5-large-v2"
             ])

  @doc """
  Returns the child spec for starting the embedding serving.
  """
  def child_spec(opts) do
    model = Keyword.get(opts, :model, @default_model)
    serving_name = serving_name(model)

    %{
      id: serving_name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc """
  Starts the Nx.Serving for this embedder.
  """
  def start_link(opts) do
    model = Keyword.get(opts, :model, @default_model)
    serving_name = serving_name(model)

    {:ok, model_info} = Bumblebee.load_model({:hf, model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model})

    # Get defn_options from Nx config (includes compiler like EXLA or EMLX)
    defn_options = Nx.Defn.default_options()

    serving =
      TextEmbedding.text_embedding(model_info, tokenizer,
        compile: [batch_size: 32, sequence_length: 512],
        defn_options: defn_options
      )

    Nx.Serving.start_link(serving: serving, name: serving_name, batch_timeout: 100)
  end

  defp serving_name(model) do
    Module.concat(__MODULE__, String.to_atom(model))
  end

  # Behaviour implementation

  @impl Arcana.Embedder
  def embed(text, opts) do
    model = Keyword.get(opts, :model, @default_model)
    intent = Keyword.get(opts, :intent)
    serving_name = serving_name(model)
    prepared_text = prepare_text(text, model, intent)

    start_metadata = %{text: text, model: model}

    :telemetry.span([:arcana, :embed], start_metadata, fn ->
      %{embedding: embedding} = Nx.Serving.batched_run(serving_name, prepared_text)
      result = Nx.to_flat_list(embedding)

      stop_metadata = %{dimensions: length(result)}
      {{:ok, result}, stop_metadata}
    end)
  end

  @doc """
  Prepares text for embedding by adding model-specific prefixes.

  E5 models require `query: ` prefix for search queries and `passage: ` prefix
  for documents. Other models return text unchanged.

  ## Options

    * `:query` - Text is a search query (adds "query: " prefix for E5)
    * `:document` - Text is document content (adds "passage: " prefix for E5)
    * `nil` - Defaults to `:document` for E5 models

  ## Examples

      iex> prepare_text("hello", "intfloat/e5-small-v2", :query)
      "query: hello"

      iex> prepare_text("hello", "intfloat/e5-small-v2", :document)
      "passage: hello"

      iex> prepare_text("hello", "BAAI/bge-small-en-v1.5", :query)
      "hello"

  """
  def prepare_text(text, model, intent) do
    if MapSet.member?(@e5_models, model) do
      case intent do
        :query -> "query: #{text}"
        :document -> "passage: #{text}"
        nil -> "passage: #{text}"
      end
    else
      text
    end
  end

  @impl Arcana.Embedder
  def dimensions(opts) do
    model = Keyword.get(opts, :model, @default_model)
    Map.get(@model_dimensions, model) || detect_dimensions(opts)
  end

  defp detect_dimensions(opts) do
    case embed("test", opts) do
      {:ok, embedding} -> length(embedding)
      _ -> raise "Could not detect dimensions for local model"
    end
  end
end
