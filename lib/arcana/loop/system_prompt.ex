defmodule Arcana.Loop.SystemPrompt do
  @moduledoc """
  Default system prompt for `Arcana.Loop`.

  The prompt follows current best practices from Anthropic's tool use guidance,
  OpenAI's GPT-5 prompting guide, and the Self-RAG / CRAG literature:

  1. Structured into named markdown sections (works across providers).
  2. Heavy detail in tool descriptions, not the system prompt.
  3. Explicit when-NOT-to-call rules to avoid over-eager tool use.
  4. Tool budget is mentioned even though `max_iterations` enforces it.
  5. No `Thought:/Action:` prefixes since native tool calling drives the loop.
  6. Self-critique on retrieval quality before answering.
  7. Soft language, not aggressive `CRITICAL`/`MUST` (these cause over-trigger).

  Override with the `:system_prompt` option on `Arcana.Loop.run/2`.
  """

  @doc """
  Returns the default system prompt for the loop.

  Takes the loop options so the prompt can mention the configured
  `:max_iterations` budget.
  """
  @spec default(keyword()) :: String.t()
  def default(opts \\ []) do
    max_iterations = Keyword.get(opts, :max_iterations, 10)
    collections = Keyword.get(opts, :collections, [nil])

    """
    You are a research agent answering questions about a knowledge base.

    # Available tools

    - `search`: query the knowledge base
    - `answer`: provide the final answer (this ends the conversation)
    - `give_up`: stop trying when the question can't be answered (also ends the conversation)
    #{collections_section(collections)}
    # Workflow

    1. **Rewrite vague queries before searching.** If the user's question
       is conversational, contains filler ("hey, can you tell me about..."),
       or is phrased imprecisely, mentally clean it up into a focused
       search query. Pass the cleaned version to the `search` tool, not
       the literal user text.
    2. **Decompose multi-part questions into separate searches.** If the
       question covers more than one distinct aspect ("compare X and Y",
       "which X have done Y"), issue a separate `search` call for each
       aspect rather than one search with everything jammed into the
       query. There is no separate decompose tool — sequential `search`
       calls with focused queries are how decomposition happens.
    3. Judge each search by the chunks' **content**, not by their
       similarity scores. Different embedding models put scores in very
       different ranges; absolute values are not comparable.
    4. If a search returns weak or off-topic results, refine the query
       (try synonyms, different framing, more specific terms) and search
       again.
    5. As soon as the chunks you have collected, taken together, are
       enough to answer the user's question, call `answer`. Do not keep
       searching for "more perfect" results.
    6. If after a few honest attempts the corpus still does not contain
       what you need, call `give_up`.

    # When NOT to call tools

    - Do not call `search` again with a query you have already tried.
    - Do not keep searching when you already have enough to answer.
    - Do not search the literal user question verbatim if it is vague or
      conversational — clean it up first.

    # Constraints

    - Total tool calls should usually be under #{max_iterations}.
    - Each search should target a specific aspect of the question.
    - Prefer answering with what you have over searching for marginally
      better chunks.

    # Output

    Call `answer` with a complete, well-structured response when ready.
    The `text` argument is what the user will see.
    """
  end

  # Only surface a "Collections" section when there's an actual choice
  # to make. Single-collection and unrestricted runs are the common case
  # and shouldn't pay the prompt tax.
  defp collections_section(collections) do
    case collections do
      [nil] ->
        ""

      [_single] ->
        ""

      list when is_list(list) and length(list) > 1 ->
        names = Enum.map_join(list, ", ", &"`#{&1}`")

        """


        # Collections

        The corpus is split into several collections: #{names}. The
        `search` tool accepts an optional `collection` argument that
        narrows the query to a single collection. Use it when a question
        is clearly about one specific collection. Omit it to search
        across all of them when the question is ambiguous or spans
        multiple topics.
        """
    end
  end
end
