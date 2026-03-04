defmodule Arcana.Grounding.InputFormatterTest do
  use ExUnit.Case, async: true

  alias Arcana.Grounding.InputFormatter

  describe "format/2" do
    test "formats single chunk" do
      chunks = [%{text: "Elixir is a functional language."}]

      result = InputFormatter.format("What is Elixir?", chunks)

      assert result == "Elixir is a functional language."
    end

    test "joins multiple chunks with newlines" do
      chunks = [
        %{text: "Elixir is functional."},
        %{text: "It runs on BEAM."},
        %{text: "Created by José Valim."}
      ]

      result = InputFormatter.format("What is Elixir?", chunks)

      assert result == "Elixir is functional.\nIt runs on BEAM.\nCreated by José Valim."
    end

    test "handles empty chunks" do
      result = InputFormatter.format("What is Elixir?", [])

      assert result == ""
    end

    test "preserves chunk text as-is" do
      chunks = [%{text: "Text with <special> chars & \"quotes\""}]

      result = InputFormatter.format("question?", chunks)

      assert result == ~s(Text with <special> chars & "quotes")
    end
  end
end
