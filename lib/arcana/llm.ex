defprotocol Arcana.LLM do
  @moduledoc """
  Protocol for LLM adapters used by Arcana.

  Arcana accepts any LLM that implements this protocol. Built-in implementations
  are provided for:

  - Model strings via Req.LLM (e.g., `"openai:gpt-4o-mini"`, `"anthropic:claude-sonnet-4-20250514"`)
  - Anonymous functions (for testing and simple use cases)

  ## Examples

  Using a model string (requires `req_llm` dependency):

      Arcana.ask("question", llm: "openai:gpt-4o-mini", repo: MyApp.Repo)

      # Or with Anthropic
      Arcana.ask("question", llm: "anthropic:claude-sonnet-4-20250514", repo: MyApp.Repo)

  Using an anonymous function:

      llm = fn prompt, context ->
        {:ok, "Generated answer"}
      end

      Arcana.ask("question", llm: llm, repo: MyApp.Repo)

  ## Custom Prompts

  Pass a `:prompt` option to `Arcana.ask/2` to customize the system prompt:

      custom_prompt = fn question, context ->
        "Answer '\#{question}' using only: \#{Enum.map_join(context, ", ", & &1.text)}"
      end

      Arcana.ask("question", llm: "openai:gpt-4o-mini", repo: MyApp.Repo, prompt: custom_prompt)

  """

  @doc """
  Completes a prompt with the given context and options.

  ## Options

  - `:system_prompt` - Custom system prompt string to use instead of the default

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec complete(t, String.t(), list(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, context, opts \\ [])
end

# Implementation for anonymous functions
defimpl Arcana.LLM, for: Function do
  def complete(fun, prompt, context, opts) do
    case Function.info(fun, :arity) do
      {:arity, 1} -> fun.(prompt)
      {:arity, 2} -> fun.(prompt, context)
      {:arity, 3} -> fun.(prompt, context, opts)
      {:arity, _} -> {:error, :invalid_function_arity}
    end
  end
end

# Req.LLM implementation for model strings like "openai:gpt-4o-mini"
if Code.ensure_loaded?(ReqLLM) do
  defimpl Arcana.LLM, for: BitString do
    def complete(model, prompt, context, opts) when is_binary(model) do
      system_message =
        case Keyword.get(opts, :system_prompt) do
          nil -> default_system_prompt(context)
          custom -> custom
        end

      llm_context =
        ReqLLM.Context.new([
          ReqLLM.Context.system(system_message),
          ReqLLM.Context.user(prompt)
        ])

      case ReqLLM.generate_text(model, llm_context) do
        {:ok, response} -> {:ok, response.text}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, e}
    end

    defp default_system_prompt(context) do
      context_text = format_context(context)

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

    defp format_context([]), do: ""

    defp format_context(context) do
      Enum.map_join(context, "\n\n---\n\n", fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)
    end
  end
end
