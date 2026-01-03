defmodule Arcana.Graph.EntityExtractor do
  @moduledoc """
  Behaviour for entity extraction in GraphRAG.

  Entity extractors identify named entities (people, organizations, locations, etc.)
  from text. Arcana provides a built-in NER implementation, but you can implement
  custom extractors for different approaches.

  ## Built-in Implementations

  - `Arcana.Graph.EntityExtractor.NER` - Local Bumblebee NER (default)

  ## Configuration

  Configure your entity extractor in `config.exs`:

      # Default: Local NER with distilbert-NER
      config :arcana, :graph,
        entity_extractor: :ner

      # Custom module implementing this behaviour
      config :arcana, :graph,
        entity_extractor: MyApp.LLMEntityExtractor

      # Custom module with options
      config :arcana, :graph,
        entity_extractor: {MyApp.LLMEntityExtractor, model: "gpt-4"}

      # Inline function
      config :arcana, :graph,
        entity_extractor: fn text, opts -> {:ok, extract_entities(text)} end

  ## Implementing a Custom Extractor

  Create a module that implements this behaviour:

      defmodule MyApp.LLMEntityExtractor do
        @behaviour Arcana.Graph.EntityExtractor

        @impl true
        def extract(text, opts) do
          llm = opts[:llm] || raise "LLM required"
          # Use LLM to extract entities...
          {:ok, entities}
        end

        # Optional: implement for batch optimization
        @impl true
        def extract_batch(texts, opts) do
          # Batch LLM call...
          {:ok, results}
        end
      end

  ## Entity Format

  Extractors must return entities as maps with at least:

  - `:name` - The entity name (required)
  - `:type` - Entity type as atom: `:person`, `:organization`, `:location`, `:concept`, `:other`

  Optional fields:

  - `:span_start` - Character offset where entity starts
  - `:span_end` - Character offset where entity ends
  - `:score` - Confidence score (0.0-1.0)
  - `:description` - Brief description of the entity

  """

  @type entity :: %{
          name: String.t(),
          type: atom(),
          span_start: non_neg_integer() | nil,
          span_end: non_neg_integer() | nil,
          score: float() | nil
        }

  @doc """
  Extracts entities from a single text.

  ## Parameters

  - `text` - The text to extract entities from
  - `opts` - Options passed from the extractor configuration

  ## Returns

  - `{:ok, entities}` - List of entity maps
  - `{:error, reason}` - On failure

  """
  @callback extract(text :: String.t(), opts :: keyword()) ::
              {:ok, [entity()]} | {:error, term()}

  @doc """
  Extracts entities from multiple texts in batch.

  Default implementation calls `extract/2` for each text sequentially.
  Override for extractors that support native batch processing.
  """
  @callback extract_batch(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [[entity()]]} | {:error, term()}

  @optional_callbacks extract_batch: 2

  @doc """
  Extracts entities using the configured extractor.

  The extractor can be:
  - A `{module, opts}` tuple where module implements this behaviour
  - A function `(text, opts) -> {:ok, entities} | {:error, reason}`

  ## Examples

      # With module
      extractor = {Arcana.Graph.EntityExtractor.NER, []}
      {:ok, entities} = EntityExtractor.extract(extractor, "Sam Altman leads OpenAI")

      # With inline function
      extractor = fn text, _opts -> {:ok, [%{name: "Test", type: :other}]} end
      {:ok, entities} = EntityExtractor.extract(extractor, "some text")

  """
  @spec extract({module(), keyword()} | function(), String.t()) ::
          {:ok, [entity()]} | {:error, term()}
  def extract({module, opts}, text) when is_atom(module) do
    module.extract(text, opts)
  end

  def extract(fun, text) when is_function(fun, 2) do
    fun.(text, [])
  end

  @doc """
  Extracts entities from multiple texts using the configured extractor.

  Falls back to sequential extraction if the module doesn't implement
  `extract_batch/2`.
  """
  @spec extract_batch({module(), keyword()} | function(), [String.t()]) ::
          {:ok, [[entity()]]} | {:error, term()}
  def extract_batch({module, opts}, texts) when is_atom(module) do
    if function_exported?(module, :extract_batch, 2) do
      module.extract_batch(texts, opts)
    else
      sequential_extract(module, opts, texts)
    end
  end

  def extract_batch(fun, texts) when is_function(fun, 2) do
    results = Enum.map(texts, fn text -> fun.(text, []) end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(results, fn {:ok, entities} -> entities end)}
    else
      {:error, :batch_failed}
    end
  end

  defp sequential_extract(module, opts, texts) do
    results = Enum.map(texts, fn text -> module.extract(text, opts) end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(results, fn {:ok, entities} -> entities end)}
    else
      {:error, :batch_failed}
    end
  end
end
