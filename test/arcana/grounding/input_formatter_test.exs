defmodule Arcana.Grounding.InputFormatterTest do
  use ExUnit.Case, async: true

  alias Arcana.Grounding.InputFormatter

  describe "format/2" do
    test "formats single chunk with question" do
      chunks = [%{text: "Elixir is a functional language."}]

      result = InputFormatter.format("What is Elixir?", chunks)

      assert result == "Elixir is a functional language. Question: What is Elixir?"
    end

    test "joins multiple chunks with passage separator" do
      chunks = [
        %{text: "Elixir is functional."},
        %{text: "It runs on BEAM."},
        %{text: "Created by José Valim."}
      ]

      result = InputFormatter.format("What is Elixir?", chunks)

      assert result ==
               "Elixir is functional.<passage_separator>It runs on BEAM.<passage_separator>Created by José Valim. Question: What is Elixir?"
    end

    test "handles empty chunks" do
      result = InputFormatter.format("What is Elixir?", [])

      assert result == " Question: What is Elixir?"
    end

    test "preserves chunk text as-is" do
      chunks = [%{text: "Text with <special> chars & \"quotes\""}]

      result = InputFormatter.format("question?", chunks)

      assert result == "Text with <special> chars & \"quotes\" Question: question?"
    end
  end
end
