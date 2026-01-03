defmodule Arcana.Graph.GraphExtractor do
  @moduledoc """
  Behaviour for combined entity and relationship extraction in GraphRAG.

  A GraphExtractor extracts both entities and relationships in a single pass,
  which is more efficient than separate extractors when using LLMs.

  ## Built-in Implementations

  - `Arcana.Graph.GraphExtractor.LLM` - LLM-based extraction (default)

  ## Configuration

  Configure your graph extractor in `config.exs`:

      # Combined extractor (efficient, 1 LLM call per chunk):
      config :arcana, :graph,
        extractor: Arcana.Graph.GraphExtractor.LLM

      # Or configure separately (flexible, 2 LLM calls per chunk):
      config :arcana, :graph,
        entity_extractor: Arcana.Graph.EntityExtractor.NER,
        relationship_extractor: Arcana.Graph.RelationshipExtractor.LLM

  When `extractor` is set, it takes priority over separate extractors.

  ## Implementing a Custom Extractor

  Create a module that implements this behaviour:

      defmodule MyApp.CustomExtractor do
        @behaviour Arcana.Graph.GraphExtractor

        @impl true
        def extract(text, opts) do
          # Extract entities and relationships together
          entities = [%{name: "Entity", type: :concept}]
          relationships = [%{source: "A", target: "B", type: "RELATED"}]
          {:ok, %{entities: entities, relationships: relationships}}
        end
      end

  ## Output Format

  Extractors must return a map with:

  - `:entities` - List of entity maps with `:name`, `:type`, and optional `:description`
  - `:relationships` - List of relationship maps with `:source`, `:target`, `:type`,
    and optional `:description` and `:strength`

  """

  @type entity :: %{
          name: String.t(),
          type: atom() | String.t(),
          description: String.t() | nil
        }

  @type relationship :: %{
          source: String.t(),
          target: String.t(),
          type: String.t(),
          description: String.t() | nil,
          strength: integer() | nil
        }

  @type extraction_result :: %{
          entities: [entity()],
          relationships: [relationship()]
        }

  @doc """
  Extracts entities and relationships from text in a single pass.

  ## Parameters

  - `text` - The source text to analyze
  - `opts` - Options passed from the extractor configuration

  ## Returns

  - `{:ok, %{entities: [...], relationships: [...]}}` - Extracted graph data
  - `{:error, reason}` - On failure

  """
  @callback extract(text :: String.t(), opts :: keyword()) ::
              {:ok, extraction_result()} | {:error, term()}

  @doc """
  Extracts graph data using the configured extractor.

  The extractor can be:
  - A `{module, opts}` tuple where module implements this behaviour
  - A function `(text, opts) -> {:ok, result} | {:error, reason}`
  - `nil` to skip extraction (returns empty result)

  ## Examples

      # With module
      extractor = {Arcana.Graph.GraphExtractor.LLM, llm: my_llm}
      {:ok, result} = GraphExtractor.extract(extractor, text)

      # With inline function
      extractor = fn text, _opts ->
        {:ok, %{entities: [], relationships: []}}
      end
      {:ok, result} = GraphExtractor.extract(extractor, text)

  """
  @spec extract(
          {module(), keyword()} | function() | nil,
          String.t()
        ) :: {:ok, extraction_result()} | {:error, term()}
  def extract(nil, _text), do: {:ok, %{entities: [], relationships: []}}

  def extract({module, opts}, text) when is_atom(module) do
    module.extract(text, opts)
  end

  def extract(fun, text) when is_function(fun, 2) do
    fun.(text, [])
  end
end
