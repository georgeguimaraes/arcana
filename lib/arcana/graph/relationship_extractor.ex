defmodule Arcana.Graph.RelationshipExtractor do
  @moduledoc """
  Behaviour for relationship extraction in GraphRAG.

  Relationship extractors identify semantic relationships between entities
  in text. Arcana provides a built-in LLM-based implementation, but you
  can implement custom extractors for different approaches.

  ## Built-in Implementations

  - `Arcana.Graph.RelationshipExtractor.LLM` - LLM-based extraction (default)
  - `Arcana.Graph.RelationshipExtractor.Cooccurrence` - Local co-occurrence based (no LLM)

  ## Configuration

  Configure your relationship extractor in `config.exs`:

      # Default: LLM-based extraction
      config :arcana, :graph,
        relationship_extractor: {Arcana.Graph.RelationshipExtractor.LLM, llm: &MyApp.llm/3}

      # Disable relationship extraction
      config :arcana, :graph,
        relationship_extractor: nil

      # Custom module implementing this behaviour
      config :arcana, :graph,
        relationship_extractor: {MyApp.PatternExtractor, patterns: [...]}

      # Inline function
      config :arcana, :graph,
        relationship_extractor: fn text, entities, opts ->
          {:ok, my_extract(text, entities, opts)}
        end

  ## Implementing a Custom Extractor

  Create a module that implements this behaviour:

      defmodule MyApp.PatternExtractor do
        @behaviour Arcana.Graph.RelationshipExtractor

        @impl true
        def extract(text, entities, opts) do
          patterns = Keyword.get(opts, :patterns, [])
          # Pattern-based extraction...
          {:ok, relationships}
        end
      end

  ## Relationship Format

  Extractors must return relationships as maps with:

  - `:source` - Name of the source entity
  - `:target` - Name of the target entity
  - `:type` - Relationship type (e.g., "WORKS_AT", "FOUNDED")
  - `:description` - Optional description
  - `:strength` - Optional strength (1-10)

  """

  @doc """
  Extracts relationships between entities from text.

  ## Parameters

  - `text` - The source text to analyze
  - `entities` - List of entity maps with `:name` and `:type`
  - `opts` - Options passed from the extractor configuration

  ## Returns

  - `{:ok, relationships}` - List of relationship maps
  - `{:error, reason}` - On failure

  """
  @callback extract(
              text :: String.t(),
              entities :: [map()],
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Extracts relationships using the configured extractor.

  The extractor can be:
  - A `{module, opts}` tuple where module implements this behaviour
  - A function `(text, entities, opts) -> {:ok, relationships} | {:error, reason}`
  - `nil` to skip relationship extraction (returns empty list)

  ## Examples

      # With module
      extractor = {Arcana.Graph.RelationshipExtractor.LLM, llm: &MyApp.llm/3}
      {:ok, relationships} = RelationshipExtractor.extract(extractor, text, entities)

      # With inline function
      extractor = fn text, entities, _opts ->
        {:ok, [%{source: "A", target: "B", type: "RELATES_TO"}]}
      end
      {:ok, relationships} = RelationshipExtractor.extract(extractor, text, entities)

      # Skip extraction
      {:ok, []} = RelationshipExtractor.extract(nil, text, entities)

  """
  def extract(nil, _text, _entities), do: {:ok, []}

  def extract({module, opts}, text, entities) when is_atom(module) do
    module.extract(text, entities, opts)
  end

  def extract(fun, text, entities) when is_function(fun, 3) do
    fun.(text, entities, [])
  end
end
