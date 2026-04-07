defmodule Arcana.Pipeline.Selector do
  @moduledoc """
  Behaviour for collection selection in the Agent pipeline.

  The selector determines which collections to search based on the question
  and available collections. This allows for both LLM-based routing (default)
  and deterministic routing based on user context, metadata, or business logic.

  ## Implementing a Custom Selector

      defmodule MyApp.TeamBasedSelector do
        @behaviour Arcana.Pipeline.Selector

        @impl true
        def select(_question, _collections, opts) do
          case opts[:context][:team] do
            "api" -> {:ok, ["api-reference", "sdk-docs"], "API team routing"}
            "mobile" -> {:ok, ["mobile-docs", "react-native"], "Mobile team routing"}
            _ -> {:ok, ["general"], "Default routing"}
          end
        end
      end

  ## Using a Custom Selector

      Pipeline.new(question, repo: repo, llm: llm)
      |> Pipeline.select(
        collections: ["api-reference", "mobile-docs", "general"],
        selector: MyApp.TeamBasedSelector,
        context: %{team: current_user.team}
      )

  ## Using an Inline Function

      Pipeline.select(ctx,
        collections: collections,
        selector: fn question, _collections, _opts ->
          if question =~ "API" do
            {:ok, ["api-docs"], "Question mentions API"}
          else
            {:ok, ["general"], "General query"}
          end
        end
      )
  """

  @doc """
  Selects which collections to search based on the question.

  ## Parameters

  - `question` - The user's question
  - `collections` - List of `{name, description}` tuples for available collections
  - `opts` - Options passed to `Pipeline.select/2`, including:
    - `:llm` - The LLM function (for LLM-based selectors)
    - `:prompt` - Custom prompt function (for LLM-based selectors)
    - `:context` - User-provided context map
    - Any other options passed to `Pipeline.select/2`

  ## Returns

  - `{:ok, selected_collections, reasoning}` - List of collection names to search
    and optional reasoning string (can be nil)
  - `{:error, reason}` - On failure, falls back to all collections
  """
  @callback select(
              question :: String.t(),
              collections :: [{name :: String.t(), description :: String.t() | nil}],
              opts :: keyword()
            ) :: {:ok, [String.t()], String.t() | nil} | {:error, term()}
end
