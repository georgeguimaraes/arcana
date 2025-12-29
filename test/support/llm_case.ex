defmodule Arcana.LLMCase do
  @moduledoc """
  Test case for LLM integration tests.

  These tests call real LLM APIs and are excluded by default.
  Run with: `mix test --include llm`

  ## Environment Variables

  Tests require API keys to be set as environment variables:

  - `ZAI_API_KEY` - Z.ai API key (for zai:* models)

  Future providers (add as needed):
  - `OPENAI_API_KEY` - OpenAI API key
  - `ANTHROPIC_API_KEY` - Anthropic API key

  ## Usage

      defmodule MyLLMTest do
        use Arcana.LLMCase, async: false

        @tag :llm
        test "calls real LLM" do
          llm = llm_config(:zai)
          # ... test with real LLM
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Arcana.LLMCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Arcana.TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Returns LLM configuration for the given provider.

  ## Providers

  - `:zai` - Z.ai with glm-4.7 model
  - `:zai_flash` - Z.ai with faster/cheaper model (when available)

  ## Examples

      llm = llm_config(:zai)
      Arcana.ask("question", llm: llm, repo: Arcana.TestRepo)
  """
  def llm_config(:zai) do
    api_key = System.get_env("ZAI_API_KEY") || raise "ZAI_API_KEY not set"
    {"zai:glm-4.7", api_key: api_key}
  end

  def llm_config(:zai_flash) do
    # Use the same model for now, can be updated when a faster model is available
    llm_config(:zai)
  end

  # Future providers - uncomment and implement as needed:
  #
  # def llm_config(:openai) do
  #   api_key = System.get_env("OPENAI_API_KEY") || raise "OPENAI_API_KEY not set"
  #   {"openai:gpt-4o-mini", api_key: api_key}
  # end
  #
  # def llm_config(:anthropic) do
  #   api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
  #   {"anthropic:claude-sonnet-4-20250514", api_key: api_key}
  # end

  @doc """
  Checks if the given LLM provider is available (API key is set).
  """
  def llm_available?(:zai), do: System.get_env("ZAI_API_KEY") != nil
  def llm_available?(_), do: false
end
