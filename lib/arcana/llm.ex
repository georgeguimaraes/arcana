defprotocol Arcana.LLM do
  @moduledoc """
  Protocol for LLM adapters used by Arcana.

  Arcana accepts any LLM that implements this protocol. Built-in implementations
  are provided for:

  - Anonymous functions (for testing and simple use cases)
  - LangChain chat models (ChatOpenAI, ChatAnthropic, etc.)

  ## Examples

  Using an anonymous function:

      llm = fn prompt, context ->
        {:ok, "Generated answer"}
      end

      Arcana.ask("question", llm: llm, repo: MyApp.Repo)

  Using a LangChain model:

      llm = LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"})

      Arcana.ask("question", llm: llm, repo: MyApp.Repo)

  """

  @doc """
  Completes a prompt with the given context.

  Returns `{:ok, response}` or `{:error, reason}`.
  """
  @spec complete(t, String.t(), list()) :: {:ok, String.t()} | {:error, term()}
  def complete(llm, prompt, context)
end

# Implementation for anonymous functions
defimpl Arcana.LLM, for: Function do
  def complete(fun, prompt, context) do
    case Function.info(fun, :arity) do
      {:arity, 1} -> fun.(prompt)
      {:arity, 2} -> fun.(prompt, context)
      {:arity, _} -> {:error, :invalid_function_arity}
    end
  end
end

# LangChain implementations
if Code.ensure_loaded?(LangChain.ChatModels.ChatOpenAI) do
  defimpl Arcana.LLM, for: LangChain.ChatModels.ChatOpenAI do
    alias LangChain.Chains.LLMChain
    alias LangChain.Message
    alias LangChain.Message.ContentPart

    def complete(chat_model, prompt, context) do
      context_text = format_context(context)

      system_message =
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

      {:ok, updated_chain} =
        %{llm: chat_model}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_system!(system_message))
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      {:ok, ContentPart.content_to_string(updated_chain.last_message.content)}
    rescue
      e -> {:error, e}
    end

    defp format_context([]), do: ""

    defp format_context(context) do
      context
      |> Enum.map(fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)
      |> Enum.join("\n\n---\n\n")
    end
  end
end

if Code.ensure_loaded?(LangChain.ChatModels.ChatAnthropic) do
  defimpl Arcana.LLM, for: LangChain.ChatModels.ChatAnthropic do
    alias LangChain.Chains.LLMChain
    alias LangChain.Message
    alias LangChain.Message.ContentPart

    def complete(chat_model, prompt, context) do
      context_text = format_context(context)

      system_message =
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

      {:ok, updated_chain} =
        %{llm: chat_model}
        |> LLMChain.new!()
        |> LLMChain.add_message(Message.new_system!(system_message))
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run()

      {:ok, ContentPart.content_to_string(updated_chain.last_message.content)}
    rescue
      e -> {:error, e}
    end

    defp format_context([]), do: ""

    defp format_context(context) do
      context
      |> Enum.map(fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)
      |> Enum.join("\n\n---\n\n")
    end
  end
end
