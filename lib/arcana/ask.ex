defmodule Arcana.Ask do
  @moduledoc """
  RAG (Retrieval Augmented Generation) question answering.

  This module handles the core ask workflow:
  1. Search for relevant context chunks
  2. Build a prompt with the context
  3. Call the LLM for an answer

  ## Usage

      {:ok, answer, context} = Arcana.ask("What is X?",
        repo: MyApp.Repo,
        llm: "openai:gpt-4o-mini"
      )

  """

  alias Arcana.LLM

  @doc """
  Asks a question using retrieved context from the knowledge base.

  Performs a search to find relevant chunks, then passes them along with
  the question to an LLM for answer generation.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:llm` - Any type implementing the `Arcana.LLM` protocol (required)
    * `:limit` - Maximum number of context chunks to retrieve (default: 5)
    * `:source_id` - Filter context to a specific source
    * `:threshold` - Minimum similarity score for context (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:collection` - Filter to a specific collection
    * `:collections` - Filter to multiple collections
    * `:prompt` - Custom prompt function `fn question, context -> system_prompt_string end`

  ## Examples

      # Basic usage
      {:ok, answer, context} = Arcana.ask("What is Elixir?",
        repo: MyApp.Repo,
        llm: "openai:gpt-4o-mini"
      )

      # With custom prompt
      {:ok, answer, _} = Arcana.ask("Summarize the docs",
        repo: MyApp.Repo,
        llm: my_llm,
        prompt: fn question, context ->
          "Be concise. Question: \#{question}"
        end
      )

  """
  def ask(question, opts) when is_binary(question) do
    repo = opts[:repo] || Application.get_env(:arcana, :repo)
    llm = opts[:llm] || Application.get_env(:arcana, :llm)

    if is_nil(llm), do: {:error, :no_llm_configured}, else: do_ask(question, opts, repo, llm)
  end

  defp do_ask(question, opts, repo, llm) do
    start_metadata = %{question: question, repo: repo}

    :telemetry.span([:arcana, :ask], start_metadata, fn ->
      search_opts =
        opts
        |> Keyword.take([:repo, :limit, :source_id, :threshold, :mode, :collection, :collections])
        |> Keyword.put_new(:limit, 5)

      case Arcana.Search.search(question, search_opts) do
        {:ok, context} -> ask_with_context(question, context, opts, llm)
        {:error, reason} -> {{:error, {:search_failed, reason}}, %{error: reason}}
      end
    end)
  end

  defp ask_with_context(question, context, opts, llm) do
    prompt_fn = Keyword.get(opts, :prompt, &default_ask_prompt/2)
    llm_opts = [system_prompt: prompt_fn.(question, context)]

    result =
      case LLM.complete(llm, question, context, llm_opts) do
        {:ok, answer} -> {:ok, answer, context}
        {:error, reason} -> {:error, reason}
      end

    stop_metadata =
      case result do
        {:ok, answer, _} -> %{answer: answer, context_count: length(context)}
        {:error, _} -> %{context_count: length(context)}
      end

    {result, stop_metadata}
  end

  defp default_ask_prompt(_question, context) do
    context_text =
      Enum.map_join(context, "\n\n---\n\n", fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)

    if context_text != "" do
      """
      Answer the user's question based on the following context.
      If the answer is not in the context, say you don't know.

      Context:
      #{context_text}
      """
    else
      "You are a helpful assistant."
    end
  end
end
