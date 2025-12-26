# LangChain Integration

This guide shows how to use Arcana with [LangChain Elixir](https://hex.pm/packages/langchain) for production-ready RAG applications.

## Setup

Add LangChain to your dependencies:

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"},
    {:langchain, "~> 0.3"}
  ]
end
```

Configure your API key:

```elixir
# config/runtime.exs
config :langchain, openai_key: System.get_env("OPENAI_API_KEY")
# or for Anthropic:
config :langchain, anthropic_key: System.get_env("ANTHROPIC_API_KEY")
```

## Basic RAG with Arcana.ask/2

The simplest integration wraps a LangChain chat model:

```elixir
alias LangChain.ChatModels.ChatOpenAI
alias LangChain.Chains.LLMChain
alias LangChain.Message

defmodule MyApp.RAG do
  def ask(question, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)

    llm_fn = fn prompt, context ->
      context_text = Enum.map_join(context, "\n\n", & &1.text)

      system_prompt = """
      Answer the user's question based on the following context.
      If the answer is not in the context, say you don't know.

      Context:
      #{context_text}
      """

      chat = ChatOpenAI.new!(%{model: "gpt-4o-mini"})

      {:ok, chain} =
        %{llm: chat}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_system!(system_prompt))
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      {:ok, LLMChain.last_message(chain).content}
    end

    Arcana.ask(question, repo: repo, llm: llm_fn, limit: 5)
  end
end
```

## Using Anthropic Claude

```elixir
alias LangChain.ChatModels.ChatAnthropic

defmodule MyApp.RAG do
  def ask(question, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)

    llm_fn = fn prompt, context ->
      context_text = Enum.map_join(context, "\n\n", & &1.text)

      chat = ChatAnthropic.new!(%{model: "claude-3-5-sonnet-latest"})

      {:ok, chain} =
        %{llm: chat}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_system!("""
          You are a helpful assistant. Answer based on the provided context.

          Context:
          #{context_text}
        """))
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      {:ok, LLMChain.last_message(chain).content}
    end

    Arcana.ask(question, repo: repo, llm: llm_fn)
  end
end
```

## Query Rewriting with LangChain

Use LangChain to power Arcana's query rewriting:

```elixir
alias LangChain.ChatModels.ChatOpenAI
alias LangChain.Chains.LLMChain
alias LangChain.Message
alias Arcana.Rewriters

defmodule MyApp.Search do
  def search(query, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)

    # Create a LangChain-powered rewriter
    rewriter = Rewriters.expand(llm: &langchain_rewrite/1)

    Arcana.search(query, repo: repo, rewriter: rewriter, mode: :hybrid)
  end

  defp langchain_rewrite(prompt) do
    chat = ChatOpenAI.new!(%{model: "gpt-4o-mini", temperature: 0})

    {:ok, chain} =
      %{llm: chat}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_user!(prompt))
      |> LLMChain.run()

    {:ok, LLMChain.last_message(chain).content}
  end
end
```

Or with custom prompts:

```elixir
# Keyword extraction for precise search
rewriter = Rewriters.keywords(
  llm: &langchain_rewrite/1,
  prompt: """
  Extract 3-5 key search terms from this query.
  Return only the terms, space-separated.

  Query: {query}
  """
)

# Query expansion for better recall
rewriter = Rewriters.expand(
  llm: &langchain_rewrite/1,
  prompt: """
  Expand this search query with synonyms and related terms.
  Keep it concise - return a single enhanced query.

  Query: {query}
  """
)
```

## Streaming Responses

For real-time streaming in LiveView:

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Chains.LLMChain
  alias LangChain.Message

  def handle_event("ask", %{"question" => question}, socket) do
    # First, get context from Arcana
    context = Arcana.search(question, repo: MyApp.Repo, limit: 5)
    context_text = Enum.map_join(context, "\n\n", & &1.text)

    # Stream the response
    send(self(), {:stream_answer, question, context_text})

    {:noreply, assign(socket, streaming: true, answer: "")}
  end

  def handle_info({:stream_answer, question, context_text}, socket) do
    live_view_pid = self()

    chat = ChatOpenAI.new!(%{model: "gpt-4o-mini", stream: true})

    callback = %{
      on_llm_new_delta: fn _chain, delta ->
        if delta.content do
          send(live_view_pid, {:chunk, delta.content})
        end
      end
    }

    Task.start(fn ->
      {:ok, _chain} =
        %{llm: chat}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_system!("""
          Answer based on this context:
          #{context_text}
        """))
        |> LLMChain.add_message(Message.new_user!(question))
        |> LLMChain.add_callback(callback)
        |> LLMChain.run()

      send(live_view_pid, :stream_done)
    end)

    {:noreply, socket}
  end

  def handle_info({:chunk, content}, socket) do
    {:noreply, update(socket, :answer, &(&1 <> content))}
  end

  def handle_info(:stream_done, socket) do
    {:noreply, assign(socket, streaming: false)}
  end
end
```

## Complete RAG Module

Here's a complete, production-ready RAG module:

```elixir
defmodule MyApp.RAG do
  @moduledoc """
  RAG (Retrieval Augmented Generation) powered by Arcana and LangChain.
  """

  alias LangChain.ChatModels.ChatOpenAI
  alias LangChain.Chains.LLMChain
  alias LangChain.Message
  alias Arcana.Rewriters

  @default_model "gpt-4o-mini"
  @default_limit 5

  @doc """
  Ask a question and get an answer based on your knowledge base.

  ## Options

    * `:repo` - Ecto repo (default: MyApp.Repo)
    * `:model` - LLM model to use (default: "gpt-4o-mini")
    * `:limit` - Number of context chunks (default: 5)
    * `:source_id` - Filter to specific source
    * `:rewrite` - Whether to rewrite the query (default: false)

  ## Examples

      {:ok, answer} = MyApp.RAG.ask("What is Elixir?")
      {:ok, answer} = MyApp.RAG.ask("How do GenServers work?", rewrite: true)

  """
  def ask(question, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)
    model = Keyword.get(opts, :model, @default_model)
    limit = Keyword.get(opts, :limit, @default_limit)
    source_id = Keyword.get(opts, :source_id)
    rewrite? = Keyword.get(opts, :rewrite, false)

    search_opts = [
      repo: repo,
      limit: limit,
      mode: :hybrid
    ]

    search_opts =
      if source_id, do: Keyword.put(search_opts, :source_id, source_id), else: search_opts

    search_opts =
      if rewrite?, do: Keyword.put(search_opts, :rewriter, query_rewriter(model)), else: search_opts

    llm_fn = fn prompt, context ->
      generate_answer(prompt, context, model)
    end

    Arcana.ask(question, Keyword.put(search_opts, :llm, llm_fn))
  end

  @doc """
  Search for relevant content without generating an answer.
  """
  def search(query, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)
    limit = Keyword.get(opts, :limit, @default_limit)
    rewrite? = Keyword.get(opts, :rewrite, false)

    search_opts = [repo: repo, limit: limit, mode: :hybrid]

    search_opts =
      if rewrite? do
        Keyword.put(search_opts, :rewriter, query_rewriter(@default_model))
      else
        search_opts
      end

    Arcana.search(query, search_opts)
  end

  defp query_rewriter(model) do
    Rewriters.expand(llm: fn prompt ->
      chat = ChatOpenAI.new!(%{model: model, temperature: 0})

      {:ok, chain} =
        %{llm: chat}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      {:ok, LLMChain.last_message(chain).content}
    end)
  end

  defp generate_answer(question, context, model) do
    context_text = Enum.map_join(context, "\n\n---\n\n", & &1.text)

    system_prompt = """
    You are a helpful assistant. Answer the user's question based ONLY on the
    provided context. If the answer is not in the context, say "I don't have
    enough information to answer that question."

    Be concise and direct. Cite specific parts of the context when relevant.

    Context:
    #{context_text}
    """

    chat = ChatOpenAI.new!(%{model: model})

    {:ok, chain} =
      %{llm: chat}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_system!(system_prompt))
      |> LLMChain.add_message(Message.new_user!(question))
      |> LLMChain.run()

    {:ok, LLMChain.last_message(chain).content}
  end
end
```

## Tips

1. **Use hybrid search** - Combines semantic understanding with keyword matching
2. **Enable query rewriting** for user-facing search - it improves recall significantly
3. **Set appropriate limits** - More context isn't always better (increases cost and noise)
4. **Use streaming** for chat interfaces - Better UX for long responses
5. **Consider caching** - LLM calls are expensive; cache common queries
