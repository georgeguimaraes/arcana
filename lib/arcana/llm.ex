defprotocol Arcana.LLM do
  @moduledoc """
  Protocol for LLM adapters used by Arcana.

  Arcana accepts any LLM that implements this protocol. Built-in implementations:

  - Model strings via Req.LLM (e.g., `"openai:gpt-4o-mini"`, `"zai:glm-4.5-flash"`)
  - Tuples of `{model_string, opts}` for passing options like `:api_key`
  - Anonymous functions (for testing)

  ## Examples

      # Model string (requires req_llm)
      Arcana.ask("question", llm: "openai:gpt-4o-mini", repo: MyApp.Repo)

      # With options
      Arcana.ask("question", llm: {"zai:glm-4.7", api_key: "key"}, repo: MyApp.Repo)

      # Function (for testing)
      Arcana.ask("question", llm: fn _prompt -> {:ok, "answer"} end, repo: MyApp.Repo)

  """

  @doc """
  Completes a prompt with the given context and options.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  def complete(llm, prompt, context, opts)
end

defmodule Arcana.LLM.Helpers do
  @moduledoc false

  @doc """
  Calls an LLM with full ReqLLM context and options, returning the complete response.

  Unlike `Arcana.LLM.complete/4` (text in, text out), this returns the full
  `ReqLLM.Response` with tool calls, usage, and finish reason. Supports the
  same config formats: model strings, `{model, opts}` tuples, and function/2 mocks.
  """
  @spec chat(term(), ReqLLM.Context.t(), keyword()) ::
          {:ok, ReqLLM.Response.t()} | {:error, term()}
  def chat(fun, context, opts) when is_function(fun, 2) do
    tools = Keyword.get(opts, :tools, [])
    fun.(context, tools)
  end

  def chat({model, llm_opts}, context, opts) when is_binary(model) and is_list(llm_opts) do
    chat(model, context, Keyword.merge(llm_opts, opts))
  end

  def chat(model, context, opts) when is_binary(model) do
    reqllm_opts =
      Keyword.take(opts, [:api_key, :temperature, :max_tokens, :provider_options, :tools])

    ReqLLM.generate_text(model, context, reqllm_opts)
  end

  def with_telemetry(model, prompt, context, fun) do
    start_metadata = %{
      model: model,
      prompt_length: String.length(prompt),
      context_count: length(context)
    }

    :telemetry.span([:arcana, :llm, :complete], start_metadata, fn ->
      result = fun.()

      stop_metadata =
        case result do
          {:ok, response} ->
            Map.merge(start_metadata, %{success: true, response_length: String.length(response)})

          {:error, reason} ->
            Map.merge(start_metadata, %{success: false, error: inspect(reason)})
        end

      {result, stop_metadata}
    end)
  end

  def format_context([]), do: ""

  def format_context(context) do
    Enum.map_join(context, "\n\n---\n\n", fn
      %{text: text} -> text
      text when is_binary(text) -> text
      other -> inspect(other)
    end)
  end

  def default_system_prompt(context) do
    case format_context(context) do
      "" ->
        "You are a helpful assistant."

      reference_text ->
        """
        You are a helpful assistant with access to the following reference material. Answer questions directly and naturally, using this information to inform your responses. Don't mention or reference the material explicitly in your answers.

        Reference material:
        #{reference_text}
        """
    end
  end
end

defimpl Arcana.LLM, for: Function do
  alias Arcana.LLM.Helpers

  def complete(fun, prompt, context, opts) do
    Helpers.with_telemetry("function", prompt, context, fn ->
      case Function.info(fun, :arity) do
        {:arity, 1} -> fun.(prompt)
        {:arity, 2} -> fun.(prompt, context)
        {:arity, 3} -> fun.(prompt, context, opts)
        {:arity, _} -> {:error, :invalid_function_arity}
      end
    end)
  end
end

if Code.ensure_loaded?(ReqLLM) do
  defimpl Arcana.LLM, for: BitString do
    alias Arcana.LLM.Helpers

    def complete(model, prompt, context, opts) do
      Helpers.with_telemetry(model, prompt, context, fn ->
        system_prompt =
          Keyword.get(opts, :system_prompt) || Helpers.default_system_prompt(context)

        llm_context =
          ReqLLM.Context.new([
            ReqLLM.Context.system(system_prompt),
            ReqLLM.Context.user(prompt)
          ])

        reqllm_opts = Keyword.take(opts, [:api_key, :temperature, :max_tokens, :provider_options])

        case Helpers.chat(model, llm_context, reqllm_opts) do
          {:ok, response} -> {:ok, ReqLLM.Response.text(response)}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end

  defimpl Arcana.LLM, for: Tuple do
    def complete({model, llm_opts}, prompt, context, opts) do
      Arcana.LLM.complete(model, prompt, context, Keyword.merge(llm_opts, opts))
    end
  end
end
