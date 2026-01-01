defmodule Arcana.Chunker.CustomTest do
  use ExUnit.Case, async: true

  alias Arcana.Chunker.Custom

  describe "chunk/2" do
    test "calls the provided function with text and opts" do
      fun = fn text, opts ->
        [%{text: text, chunk_index: 0, token_count: opts[:token_count] || 10}]
      end

      chunks = Custom.chunk("Hello world", fun: fun, token_count: 5)

      assert chunks == [%{text: "Hello world", chunk_index: 0, token_count: 5}]
    end

    test "passes through options excluding :fun" do
      :persistent_term.put(:test_opts, nil)

      fun = fn _text, opts ->
        :persistent_term.put(:test_opts, opts)
        [%{text: "chunk", chunk_index: 0, token_count: 1}]
      end

      Custom.chunk("text", fun: fun, chunk_size: 100, format: :markdown)

      opts = :persistent_term.get(:test_opts)
      assert Keyword.get(opts, :chunk_size) == 100
      assert Keyword.get(opts, :format) == :markdown
      refute Keyword.has_key?(opts, :fun)

      :persistent_term.erase(:test_opts)
    end

    test "returns multiple chunks from the function" do
      fun = fn text, _opts ->
        text
        |> String.split(" ")
        |> Enum.with_index()
        |> Enum.map(fn {word, idx} ->
          %{text: word, chunk_index: idx, token_count: 1}
        end)
      end

      chunks = Custom.chunk("one two three", fun: fun)

      assert length(chunks) == 3
      assert Enum.map(chunks, & &1.text) == ["one", "two", "three"]
      assert Enum.map(chunks, & &1.chunk_index) == [0, 1, 2]
    end

    test "handles empty text" do
      fun = fn "", _opts -> [] end

      chunks = Custom.chunk("", fun: fun)

      assert chunks == []
    end

    test "raises when :fun option is missing" do
      assert_raise KeyError, ~r/:fun/, fn ->
        Custom.chunk("text", [])
      end
    end

    test "emits telemetry events" do
      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "#{inspect(ref)}-start",
        [:arcana, :chunk, :start],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :telemetry.attach(
        "#{inspect(ref)}-stop",
        [:arcana, :chunk, :stop],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      fun = fn text, _opts ->
        [%{text: text, chunk_index: 0, token_count: 5}]
      end

      Custom.chunk("Hello", fun: fun)

      assert_receive {:telemetry, [:arcana, :chunk, :start], _measurements, start_metadata}
      assert start_metadata.text_length == 5

      assert_receive {:telemetry, [:arcana, :chunk, :stop], measurements, stop_metadata}
      assert is_integer(measurements.duration)
      assert stop_metadata.chunk_count == 1

      :telemetry.detach("#{inspect(ref)}-start")
      :telemetry.detach("#{inspect(ref)}-stop")
    end
  end
end
