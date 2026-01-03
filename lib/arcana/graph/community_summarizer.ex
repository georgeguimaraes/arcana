defmodule Arcana.Graph.CommunitySummarizer do
  @moduledoc """
  Behaviour for community summarization in GraphRAG.

  Community summarizers generate natural language descriptions of
  entity communities. These summaries provide high-level context
  for global queries that need broad understanding rather than
  specific document chunks.

  ## Built-in Implementations

  - `Arcana.Graph.CommunitySummarizer.LLM` - LLM-based summarization (default)

  ## Configuration

  Configure your community summarizer in `config.exs`:

      # Default: LLM-based summarization
      config :arcana, :graph,
        community_summarizer: {Arcana.Graph.CommunitySummarizer.LLM, llm: &MyApp.llm/3}

      # Disable summarization (communities won't have summaries)
      config :arcana, :graph,
        community_summarizer: nil

      # Custom module implementing this behaviour
      config :arcana, :graph,
        community_summarizer: {MyApp.ExtractiveSum, max_sentences: 3}

      # Inline function
      config :arcana, :graph,
        community_summarizer: fn entities, relationships, _opts ->
          {:ok, "Community with \#{length(entities)} entities"}
        end

  ## Implementing a Custom Summarizer

  Create a module that implements this behaviour:

      defmodule MyApp.ExtractiveSum do
        @behaviour Arcana.Graph.CommunitySummarizer

        @impl true
        def summarize(entities, relationships, opts) do
          max_sentences = Keyword.get(opts, :max_sentences, 3)
          # Extract key sentences from entity descriptions...
          {:ok, summary}
        end
      end

  ## Summary Format

  Summarizers should return a concise string (2-5 sentences) that:
  - Identifies the community's central theme or domain
  - Names the most important entities
  - Describes key relationships between entities

  """

  @type entity :: %{name: String.t(), type: atom() | String.t(), description: String.t() | nil}
  @type relationship :: %{
          source: String.t(),
          target: String.t(),
          type: String.t(),
          description: String.t() | nil
        }

  @doc """
  Generates a summary for a community.

  ## Parameters

  - `entities` - List of entity maps with `:name`, `:type`, and optional `:description`
  - `relationships` - List of relationship maps connecting entities
  - `opts` - Options passed from the summarizer configuration

  ## Returns

  - `{:ok, summary}` - The generated summary string
  - `{:error, reason}` - On failure

  """
  @callback summarize(
              entities :: [entity()],
              relationships :: [relationship()],
              opts :: keyword()
            ) :: {:ok, String.t()} | {:error, term()}

  @default_threshold 10

  @doc """
  Generates a summary using the configured summarizer.

  The summarizer can be:
  - A `{module, opts}` tuple where module implements this behaviour
  - A function `(entities, relationships, opts) -> {:ok, summary} | {:error, reason}`
  - `nil` to skip summarization (returns empty string)

  Falls back to LLM summarizer if not configured but `:llm` option is provided.
  """
  @spec summarize([entity()], [relationship()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def summarize(entities, relationships, opts \\ []) do
    summarizer = get_summarizer(opts)
    do_summarize(summarizer, entities, relationships, opts)
  end

  defp get_summarizer(opts) do
    Keyword.get_lazy(opts, :community_summarizer, fn ->
      get_in(Application.get_env(:arcana, :graph, []), [:community_summarizer])
    end)
  end

  defp do_summarize(nil, entities, relationships, opts) do
    # If no summarizer configured but LLM provided, use LLM summarizer
    if Keyword.has_key?(opts, :llm) do
      do_summarize({Arcana.Graph.CommunitySummarizer.LLM, []}, entities, relationships, opts)
    else
      {:ok, ""}
    end
  end

  defp do_summarize({module, mod_opts}, entities, relationships, opts) do
    merged_opts = Keyword.merge(mod_opts, opts)
    module.summarize(entities, relationships, merged_opts)
  end

  defp do_summarize(module, entities, relationships, opts) when is_atom(module) do
    module.summarize(entities, relationships, opts)
  end

  defp do_summarize(func, entities, relationships, opts) when is_function(func, 3) do
    func.(entities, relationships, opts)
  end

  @doc """
  Checks if a community needs its summary regenerated.

  ## Regeneration Triggers

    - `dirty: true` - Community was modified since last summary
    - `change_count >= threshold` - Many changes accumulated
    - `summary: nil` - No summary exists yet

  ## Options

    - `:threshold` - Number of changes before regeneration (default: 10)

  """
  @spec needs_regeneration?(map(), keyword()) :: boolean()
  def needs_regeneration?(community, opts \\ [])

  def needs_regeneration?(community, opts) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    cond do
      Map.get(community, :dirty, false) -> true
      is_nil(Map.get(community, :summary)) -> true
      Map.get(community, :change_count, 0) >= threshold -> true
      true -> false
    end
  end

  @doc """
  Returns a map of fields to reset after regenerating a summary.

  Use with `Ecto.Changeset.change/2` to mark a community as clean:

      community
      |> Community.changeset(CommunitySummarizer.reset_change_tracking())
      |> Repo.update()

  """
  @spec reset_change_tracking() :: %{change_count: 0, dirty: false}
  def reset_change_tracking do
    %{change_count: 0, dirty: false}
  end
end
