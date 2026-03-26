defmodule Arcana.EndToEnd.RecursiveTest do
  @moduledoc """
  End-to-end tests for Arcana.Recursive.explore/2 with real LLM APIs.

  Run with: `mix test --include end_to_end`
  Or just this file: `mix test test/arcana/end_to_end/recursive_test.exs --include end_to_end`

  Requires ZAI_API_KEY environment variable.
  """
  use Arcana.LLMCase, async: true

  @moduletag timeout: :timer.minutes(5)

  @elixir_doc """
  Elixir is a dynamic, functional programming language designed for building
  scalable and maintainable applications. It runs on the Erlang VM (BEAM),
  known for running low-latency, distributed, and fault-tolerant systems.

  Elixir was created by José Valim in 2011. It leverages the Erlang VM,
  which has been battle-tested for decades in telecom systems. The language
  emphasizes immutability, pattern matching, and the actor model for
  concurrency via lightweight processes.

  Key features include:
  - Pattern matching for control flow
  - The pipe operator |> for function composition
  - Protocols for polymorphism
  - Macros for metaprogramming
  - OTP (Open Telecom Platform) for building fault-tolerant systems
  - Mix build tool and Hex package manager
  """

  @phoenix_doc """
  Phoenix is a web framework for Elixir that provides a productive toolkit
  for building rich, interactive web applications. It is known for its
  performance and real-time capabilities through WebSocket-based channels.

  Phoenix LiveView allows developers to build interactive, real-time user
  interfaces without writing JavaScript. Updates are pushed to the client
  over WebSocket connections, providing a seamless experience.

  Phoenix includes:
  - Router for request dispatching
  - Controllers and views for request handling
  - Ecto integration for database access
  - Channels for real-time communication
  - LiveView for server-rendered interactive UIs
  - PubSub for distributed messaging
  - Telemetry for observability
  """

  describe "Arcana.Recursive.explore/2 with content" do
    @tag :end_to_end
    test "explores single document and answers question" do
      llm = llm_config(:zai)

      {:ok, result} =
        Arcana.Recursive.explore(
          "Who created Elixir and when?",
          model: llm,
          content: @elixir_doc
        )

      assert is_binary(result.answer)
      assert String.length(result.answer) > 10

      answer_lower = String.downcase(result.answer)
      assert answer_lower =~ "valim" or answer_lower =~ "2011" or answer_lower =~ "josé"

      assert result.step_count > 0
      assert result.usage.input_tokens > 0
      assert result.usage.output_tokens > 0
      assert is_list(result.trace)
    end

    @tag :end_to_end
    test "explores multiple documents" do
      llm = llm_config(:zai)

      {:ok, result} =
        Arcana.Recursive.explore(
          "What is the relationship between Elixir and Phoenix?",
          model: llm,
          content: [
            %{name: "elixir.md", text: @elixir_doc},
            %{name: "phoenix.md", text: @phoenix_doc}
          ]
        )

      assert is_binary(result.answer)
      assert String.length(result.answer) > 10

      answer_lower = String.downcase(result.answer)
      assert answer_lower =~ "phoenix" or answer_lower =~ "web" or answer_lower =~ "framework"
    end

    @tag :end_to_end
    test "trace contains tool calls" do
      llm = llm_config(:zai)

      {:ok, result} =
        Arcana.Recursive.explore(
          "What features does Elixir have?",
          model: llm,
          content: @elixir_doc,
          max_steps: 10
        )

      assert length(result.trace) > 0

      tools_used = Enum.map(result.trace, & &1.tool) |> Enum.uniq()
      # Should use at least grep or read_section
      assert Enum.any?(tools_used, &(&1 in ["grep", "read_section"]))
    end
  end

  describe "Arcana.Recursive.explore/2 with collection" do
    @tag :end_to_end
    test "stores and explores from collection" do
      llm = llm_config(:zai)

      {:ok, _doc1} =
        Arcana.Recursive.store(@elixir_doc,
          repo: Arcana.TestRepo,
          collection: "e2e-recursive",
          name: "elixir.md"
        )

      {:ok, _doc2} =
        Arcana.Recursive.store(@phoenix_doc,
          repo: Arcana.TestRepo,
          collection: "e2e-recursive",
          name: "phoenix.md"
        )

      {:ok, result} =
        Arcana.Recursive.explore(
          "What real-time features does Phoenix provide?",
          model: llm,
          repo: Arcana.TestRepo,
          collections: ["e2e-recursive"]
        )

      assert is_binary(result.answer)
      assert String.length(result.answer) > 10

      answer_lower = String.downcase(result.answer)

      assert answer_lower =~ "liveview" or answer_lower =~ "channel" or
               answer_lower =~ "websocket" or answer_lower =~ "real-time" or
               answer_lower =~ "real time"
    end
  end

  describe "Arcana.Recursive.explore/2 with on_trace_entry" do
    @tag :end_to_end
    test "streams trace entries in real time" do
      llm = llm_config(:zai)
      test_pid = self()

      {:ok, result} =
        Arcana.Recursive.explore(
          "What is Elixir?",
          model: llm,
          content: @elixir_doc,
          max_steps: 10,
          on_trace_entry: fn entry -> send(test_pid, {:trace, entry}) end
        )

      # Collect streamed entries
      streamed =
        Stream.repeatedly(fn ->
          receive do
            {:trace, entry} -> entry
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(&(&1 != nil))

      assert length(streamed) > 0
      assert length(streamed) == length(result.trace)

      # All entries should have session_id and depth
      for entry <- streamed do
        assert Map.has_key?(entry, :session_id)
        assert Map.has_key?(entry, :depth)
        assert Map.has_key?(entry, :tool)
      end
    end
  end
end
