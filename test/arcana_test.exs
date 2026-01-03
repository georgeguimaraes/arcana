defmodule ArcanaTest do
  use Arcana.DataCase, async: true

  describe "ask/2" do
    setup do
      {:ok, _doc} =
        Arcana.ingest(
          "The capital of France is Paris. Paris is known for the Eiffel Tower.",
          repo: Repo
        )

      :ok
    end

    test "works with any type implementing Arcana.LLM protocol" do
      # Anonymous function implements the protocol via Function
      llm = fn prompt, context ->
        {:ok, "Answer to: #{prompt} with #{length(context)} chunks"}
      end

      {:ok, answer, _results} = Arcana.ask("What is the capital?", repo: Repo, llm: llm)

      assert answer =~ "What is the capital?"
      assert answer =~ "chunks"
    end

    test "accepts model string via protocol (requires req_llm)" do
      # Verify that a model string is accepted (protocol is implemented for BitString)
      # We can't actually call the API, but we can verify the protocol implementation exists
      model = "openai:gpt-4o-mini"

      # This should not raise - the protocol implementation exists
      assert Arcana.LLM.impl_for(model) != nil
    end

    test "returns answer using retrieved context" do
      # Use a test LLM that echoes the context
      test_llm = fn prompt, _context ->
        {:ok, "Answer based on: #{prompt}"}
      end

      {:ok, answer, _results} =
        Arcana.ask("What is the capital of France?",
          repo: Repo,
          llm: test_llm
        )

      assert answer =~ "capital of France"
    end

    test "passes retrieved chunks as context to LLM" do
      # Track what context was passed to the LLM
      test_pid = self()

      test_llm = fn prompt, context ->
        send(test_pid, {:llm_called, prompt, context})
        {:ok, "Test answer"}
      end

      {:ok, _answer, _results} =
        Arcana.ask("Tell me about Paris",
          repo: Repo,
          llm: test_llm
        )

      assert_receive {:llm_called, prompt, context}
      assert prompt =~ "Tell me about Paris"
      assert is_list(context)
      assert not Enum.empty?(context)
      # Context should contain the ingested document chunks
      assert Enum.any?(context, fn chunk -> chunk.text =~ "Paris" end)
    end

    test "returns error when no LLM configured" do
      assert {:error, :no_llm_configured} = Arcana.ask("test", repo: Repo)
    end

    test "respects search options like limit and threshold" do
      test_pid = self()

      test_llm = fn _prompt, context ->
        send(test_pid, {:context_size, length(context)})
        {:ok, "Answer"}
      end

      {:ok, _, _} =
        Arcana.ask("Paris",
          repo: Repo,
          llm: test_llm,
          limit: 1
        )

      assert_receive {:context_size, 1}
    end

    test "accepts custom prompt function" do
      test_pid = self()

      # LLM that captures the system prompt it receives
      test_llm = fn prompt, context, opts ->
        send(test_pid, {:llm_called, prompt, context, opts})
        {:ok, "Answer"}
      end

      custom_prompt = fn question, context ->
        "CUSTOM SYSTEM: Answer '#{question}' using #{length(context)} sources"
      end

      {:ok, _, _} =
        Arcana.ask("What is Paris?",
          repo: Repo,
          llm: test_llm,
          prompt: custom_prompt
        )

      assert_receive {:llm_called, _prompt, _context, opts}
      assert opts[:system_prompt] =~ "CUSTOM SYSTEM"
      assert opts[:system_prompt] =~ "What is Paris?"
    end
  end
end
