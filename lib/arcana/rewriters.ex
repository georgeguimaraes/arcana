defmodule Arcana.Rewriters do
  @moduledoc """
  Built-in query rewriter helpers for common rewriting strategies.

  Each helper can be used in two ways:

  1. Direct call with a query:
      {:ok, rewritten} = Rewriters.expand("ML models", llm: my_llm_fn)

  2. As a rewriter function for `Arcana.search/2`:
      rewriter = Rewriters.expand(llm: my_llm_fn)
      {:ok, results} = Arcana.search("ML models", repo: Repo, rewriter: rewriter)

  The `:llm` option accepts any type implementing the `Arcana.LLM` protocol,
  including anonymous functions and LangChain chat models.

  All helpers accept a `:prompt` option to customize the prompt template.
  Use `{query}` as a placeholder for the original query.
  """

  alias Arcana.LLM

  @default_expand_prompt """
  Expand this search query with synonyms and related terms to improve retrieval.
  Return only the expanded query, nothing else.

  Query: {query}
  """

  @default_keywords_prompt """
  Extract the key search terms from this query.
  Return only the important keywords separated by spaces, nothing else.

  Query: {query}
  """

  @default_decompose_prompt """
  Break this complex question into simpler sub-queries.
  Return each sub-query on a new line, nothing else.

  Query: {query}
  """

  @doc """
  Expands a query with synonyms and related terms.

  ## Options

    * `:llm` - LLM function `fn(prompt) -> {:ok, result} | {:error, reason}` (required)
    * `:prompt` - Custom prompt template with `{query}` placeholder

  ## Examples

      # Direct use
      {:ok, expanded} = Rewriters.expand("ML", llm: my_llm)

      # As rewriter function
      rewriter = Rewriters.expand(llm: my_llm)
      {:ok, results} = Arcana.search("ML", repo: Repo, rewriter: rewriter)

  """
  def expand(query, opts) when is_binary(query) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_template = Keyword.get(opts, :prompt, @default_expand_prompt)

    prompt = String.replace(prompt_template, "{query}", query)
    LLM.complete(llm, prompt, [], [])
  end

  def expand(opts) when is_list(opts) do
    fn query -> expand(query, opts) end
  end

  @doc """
  Extracts key search terms from a query.

  ## Options

    * `:llm` - LLM function `fn(prompt) -> {:ok, result} | {:error, reason}` (required)
    * `:prompt` - Custom prompt template with `{query}` placeholder

  ## Examples

      {:ok, keywords} = Rewriters.keywords("What are the best practices?", llm: my_llm)

  """
  def keywords(query, opts) when is_binary(query) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_template = Keyword.get(opts, :prompt, @default_keywords_prompt)

    prompt = String.replace(prompt_template, "{query}", query)
    LLM.complete(llm, prompt, [], [])
  end

  def keywords(opts) when is_list(opts) do
    fn query -> keywords(query, opts) end
  end

  @doc """
  Decomposes a complex question into simpler sub-queries.

  ## Options

    * `:llm` - LLM function `fn(prompt) -> {:ok, result} | {:error, reason}` (required)
    * `:prompt` - Custom prompt template with `{query}` placeholder

  ## Examples

      {:ok, sub_queries} = Rewriters.decompose("Complex multi-part question?", llm: my_llm)

  """
  def decompose(query, opts) when is_binary(query) do
    llm = Keyword.fetch!(opts, :llm)
    prompt_template = Keyword.get(opts, :prompt, @default_decompose_prompt)

    prompt = String.replace(prompt_template, "{query}", query)
    LLM.complete(llm, prompt, [], [])
  end

  def decompose(opts) when is_list(opts) do
    fn query -> decompose(query, opts) end
  end
end
