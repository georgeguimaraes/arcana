defmodule Arcana.Graph.CommunityDetector do
  @moduledoc """
  Behaviour for community detection in GraphRAG.

  Community detectors partition entities into groups based on their
  relationships. Arcana provides a built-in Leiden implementation,
  but you can implement custom detectors for different algorithms.

  ## Built-in Implementations

  - `Arcana.Graph.CommunityDetector.Leiden` - Leiden algorithm via Leidenfold (Rust NIF)

  ## Installation

  To enable community detection, add `leidenfold` to your dependencies:

      defp deps do
        [
          {:arcana, "~> 1.2"},
          {:leidenfold, "~> 0.2"}
        ]
      end

  Precompiled binaries are available for macOS (Apple Silicon) and Linux (x86_64, ARM64).

  ## Configuration

  Configure your community detector in `config.exs`:

      # Default: Leiden algorithm (requires leidenfold)
      config :arcana, :graph,
        community_detector: :leiden

      # Disable community detection
      config :arcana, :graph,
        community_detector: nil

      # Custom module implementing this behaviour
      config :arcana, :graph,
        community_detector: MyApp.LouvainDetector

      # Custom module with options
      config :arcana, :graph,
        community_detector: {MyApp.LouvainDetector, resolution: 0.5}

      # Inline function
      config :arcana, :graph,
        community_detector: fn entities, relationships, opts ->
          {:ok, my_detect(entities, relationships, opts)}
        end

  ## Implementing a Custom Detector

  Create a module that implements this behaviour:

      defmodule MyApp.LouvainDetector do
        @behaviour Arcana.Graph.CommunityDetector

        @impl true
        def detect(entities, relationships, opts) do
          resolution = Keyword.get(opts, :resolution, 1.0)
          # Run Louvain algorithm...
          {:ok, communities}
        end
      end

  ## Community Format

  Detectors must return communities as maps with:

  - `:level` - Hierarchy level (0 = finest, higher = coarser)
  - `:entity_ids` - List of entity IDs in this community

  """

  @doc """
  Detects communities in the entity graph.

  ## Parameters

  - `entities` - List of entity maps with `:id` and `:name`
  - `relationships` - List of relationship maps with `:source_id`, `:target_id`, `:strength`
  - `opts` - Options passed from the detector configuration

  ## Returns

  - `{:ok, communities}` - List of community maps
  - `{:error, reason}` - On failure

  """
  @callback detect(
              entities :: [map()],
              relationships :: [map()],
              opts :: keyword()
            ) :: {:ok, [map()]} | {:error, term()}

  @doc """
  Detects communities using the configured detector.

  The detector can be:
  - A `{module, opts}` tuple where module implements this behaviour
  - A function `(entities, relationships, opts) -> {:ok, communities} | {:error, reason}`
  - `nil` to skip community detection (returns empty list)

  ## Examples

      # With module
      detector = {Arcana.Graph.CommunityDetector.Leiden, resolution: 1.0}
      {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

      # With inline function
      detector = fn entities, _rels, _opts ->
        {:ok, [%{level: 0, entity_ids: Enum.map(entities, & &1.id)}]}
      end
      {:ok, communities} = CommunityDetector.detect(detector, entities, relationships)

      # Skip detection
      {:ok, []} = CommunityDetector.detect(nil, entities, relationships)

  """
  def detect(nil, _entities, _relationships), do: {:ok, []}

  def detect({module, opts}, entities, relationships) when is_atom(module) do
    module.detect(entities, relationships, opts)
  end

  def detect(fun, entities, relationships) when is_function(fun, 3) do
    fun.(entities, relationships, [])
  end
end
