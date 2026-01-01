# LLM Integration

This guide shows how to use Arcana with [Req.LLM](https://hex.pm/packages/req_llm) for production-ready RAG applications.

## Setup

Add `req_llm` to your dependencies:

```elixir
def deps do
  [
    {:arcana, "~> 0.1.0"},
    {:req_llm, "~> 1.2"}
  ]
end
```

Configure your API key:

```elixir
# config/runtime.exs
config :req_llm, :openai, api_key: System.get_env("OPENAI_API_KEY")
# or for Anthropic:
config :req_llm, :anthropic, api_key: System.get_env("ANTHROPIC_API_KEY")
```

## Basic RAG with Arcana.ask/2

Pass a model string directly to `Arcana.ask/2`:

```elixir
# OpenAI
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini"
)

# Anthropic
{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "anthropic:claude-sonnet-4-20250514"
)
```

The model string format is `provider:model-name`. Req.LLM supports 45+ providers including OpenAI, Anthropic, Google, Groq, and OpenRouter.

## Custom Prompts

Use the `:prompt` option for custom system prompts:

```elixir
custom_prompt = fn question, context ->
  context_text = Enum.map_join(context, "\n\n", & &1.text)

  """
  You are a helpful assistant. Answer the question based only on the provided context.
  Be concise and cite specific passages when possible.

  Context:
  #{context_text}
  """
end

{:ok, answer} = Arcana.ask("What is Elixir?",
  repo: MyApp.Repo,
  llm: "openai:gpt-4o-mini",
  prompt: custom_prompt,
  limit: 5
)
```

## Custom RAG Module

Wrap Arcana in a module for cleaner usage:

```elixir
defmodule MyApp.RAG do
  @default_model "openai:gpt-4o-mini"
  @default_limit 5

  def ask(question, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)
    model = Keyword.get(opts, :model, @default_model)
    limit = Keyword.get(opts, :limit, @default_limit)
    source_id = Keyword.get(opts, :source_id)

    search_opts = [
      repo: repo,
      llm: model,
      limit: limit,
      mode: :hybrid
    ]

    search_opts =
      if source_id, do: Keyword.put(search_opts, :source_id, source_id), else: search_opts

    Arcana.ask(question, search_opts)
  end

  def search(query, opts \\ []) do
    repo = Keyword.get(opts, :repo, MyApp.Repo)
    limit = Keyword.get(opts, :limit, @default_limit)

    case Arcana.search(query, repo: repo, limit: limit, mode: :hybrid) do
      {:ok, results} -> results
      {:error, _reason} -> []
    end
  end
end
```

## Streaming Responses

For real-time streaming in LiveView, use Req.LLM's streaming directly with Arcana's search:

```elixir
defmodule MyAppWeb.ChatLive do
  use MyAppWeb, :live_view

  def handle_event("ask", %{"question" => question}, socket) do
    # Get context from Arcana
    {:ok, context} = Arcana.search(question, repo: MyApp.Repo, limit: 5)
    context_text = Enum.map_join(context, "\n\n", & &1.text)

    # Stream the response
    send(self(), {:stream_answer, question, context_text})

    {:noreply, assign(socket, streaming: true, answer: "")}
  end

  def handle_info({:stream_answer, question, context_text}, socket) do
    live_view_pid = self()

    Task.start(fn ->
      llm_context =
        ReqLLM.Context.new([
          ReqLLM.Context.system("""
            Answer based on this context:
            #{context_text}
          """),
          ReqLLM.Context.user(question)
        ])

      {:ok, response} = ReqLLM.stream_text("openai:gpt-4o-mini", llm_context)

      response
      |> ReqLLM.StreamResponse.tokens()
      |> Stream.each(fn chunk ->
        send(live_view_pid, {:chunk, chunk})
      end)
      |> Stream.run()

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

## Agentic RAG

For complex questions, use the Agent pipeline:

```elixir
llm = fn prompt -> ReqLLM.generate_text!("openai:gpt-4o-mini", prompt) end

ctx =
  Arcana.Agent.new("Compare Elixir and Erlang features", repo: MyApp.Repo, llm: llm)
  |> Arcana.Agent.select(collections: ["elixir-docs", "erlang-docs"])
  |> Arcana.Agent.decompose()
  |> Arcana.Agent.search(self_correct: true)
  |> Arcana.Agent.answer()

ctx.answer
```

All pipeline steps accept custom prompt options:

```elixir
ctx
|> Agent.select(collections: [...], prompt: fn question, collections -> "..." end)
|> Agent.decompose(prompt: fn question -> "..." end)
|> Agent.search(
  self_correct: true,
  sufficient_prompt: fn question, chunks -> "..." end,
  rewrite_prompt: fn question, chunks -> "..." end
)
|> Agent.answer(prompt: fn question, chunks -> "..." end)
```

## Cost Tracking

Req.LLM includes built-in cost tracking via telemetry. Attach a handler to track LLM costs:

```elixir
defmodule MyApp.LLMLogger do
  require Logger

  def setup do
    :telemetry.attach(
      "llm-cost-logger",
      [:req_llm, :token_usage],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:req_llm, :token_usage], measurements, metadata, _) do
    Logger.info("""
    LLM Usage:
      Model: #{metadata.model}
      Input tokens: #{measurements.input_tokens}
      Output tokens: #{measurements.output_tokens}
      Cost: $#{measurements.total_cost}
    """)
  end
end
```

## Tips

1. **Use hybrid search** - Combines semantic understanding with keyword matching
2. **Set appropriate limits** - More context isn't always better (increases cost and noise)
3. **Use streaming** for chat interfaces - Better UX for long responses
4. **Monitor costs** - Attach telemetry handlers to track LLM spending
5. **Consider caching** - LLM calls are expensive; cache common queries
