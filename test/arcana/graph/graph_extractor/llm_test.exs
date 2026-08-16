defmodule Arcana.Graph.GraphExtractor.LLMTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.GraphExtractor.LLM

  # Helper to create a mock LLM function
  defp mock_llm(response) do
    fn _prompt -> {:ok, response} end
  end

  # Pulls the fenced JSON example out of the prompt's output format section
  defp example_json(prompt) do
    [_, json] = Regex.run(~r/```json\n(.*?)```/s, prompt)
    json
  end

  describe "extract/2" do
    test "extracts entities and relationships from text" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "Sam Altman", "type": "person", "description": "CEO of OpenAI"},
            {"name": "OpenAI", "type": "organization", "description": "AI research company"}
          ],
          "relationships": [
            {"source": "Sam Altman", "target": "OpenAI", "type": "LEADS", "strength": 9}
          ]
        }
        """)

      {:ok, result} = LLM.extract("Sam Altman leads OpenAI.", llm: llm)

      assert length(result.entities) == 2
      assert length(result.relationships) == 1

      [sam, openai] = Enum.sort_by(result.entities, & &1.name)
      assert sam.name == "OpenAI"
      assert openai.name == "Sam Altman"

      [rel] = result.relationships
      assert rel.source == "Sam Altman"
      assert rel.target == "OpenAI"
      assert rel.type == "LEADS"
    end

    test "returns empty result for empty text" do
      llm = mock_llm(~s|{"entities": [], "relationships": []}|)

      {:ok, result} = LLM.extract("", llm: llm)

      assert result.entities == []
      assert result.relationships == []
    end

    test "normalizes entity types to lowercase" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "Python", "type": "LANGUAGE"}
          ],
          "relationships": []
        }
        """)

      {:ok, result} = LLM.extract("Python is a language.", llm: llm)

      [entity] = result.entities
      assert entity.type == "language"
    end

    test "normalizes relationship types to UPPER_SNAKE_CASE" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "A", "type": "concept"},
            {"name": "B", "type": "concept"}
          ],
          "relationships": [
            {"source": "A", "target": "B", "type": "relates to"}
          ]
        }
        """)

      {:ok, result} = LLM.extract("A relates to B.", llm: llm)

      [rel] = result.relationships
      assert rel.type == "RELATES_TO"
    end

    test "filters out relationships with unknown entities" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "A", "type": "concept"}
          ],
          "relationships": [
            {"source": "A", "target": "Unknown", "type": "RELATES_TO"}
          ]
        }
        """)

      {:ok, result} = LLM.extract("A relates to something.", llm: llm)

      assert result.relationships == []
    end

    test "clamps strength to 1-10 range" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "A", "type": "concept"},
            {"name": "B", "type": "concept"}
          ],
          "relationships": [
            {"source": "A", "target": "B", "type": "RELATES_TO", "strength": 15}
          ]
        }
        """)

      {:ok, result} = LLM.extract("A relates to B.", llm: llm)

      [rel] = result.relationships
      assert rel.strength == 10
    end

    test "handles markdown code blocks in response" do
      llm =
        mock_llm("""
        ```json
        {
          "entities": [{"name": "Test", "type": "concept"}],
          "relationships": []
        }
        ```
        """)

      {:ok, result} = LLM.extract("Test.", llm: llm)

      assert length(result.entities) == 1
    end

    test "returns error for invalid JSON" do
      llm = mock_llm("not valid json")

      {:error, {:json_parse_error, _}} = LLM.extract("Some text.", llm: llm)
    end

    test "requires llm option" do
      assert_raise KeyError, fn ->
        LLM.extract("Some text.", [])
      end
    end

    test "filters self-referencing relationships" do
      llm =
        mock_llm("""
        {
          "entities": [
            {"name": "A", "type": "concept"}
          ],
          "relationships": [
            {"source": "A", "target": "A", "type": "RELATES_TO"}
          ]
        }
        """)

      {:ok, result} = LLM.extract("A relates to itself.", llm: llm)

      assert result.relationships == []
    end
  end

  describe "build_prompt/1" do
    test "includes text in prompt" do
      prompt = LLM.build_prompt("Sam Altman leads OpenAI.")

      assert prompt =~ "Sam Altman leads OpenAI."
    end

    test "includes entity types" do
      prompt = LLM.build_prompt("Some text.")

      assert prompt =~ "person"
      assert prompt =~ "organization"
      assert prompt =~ "location"
    end

    test "includes relationship instructions" do
      prompt = LLM.build_prompt("Some text.")

      assert prompt =~ "relationships"
      assert prompt =~ "UPPER_SNAKE_CASE"
    end

    # The prompt shows the model an example response, so that example has to
    # be output we'd actually keep: every relationship endpoint must name an
    # entity in the same example, or parse_and_validate drops it and we're
    # teaching the model a shape we discard.
    test "the output format example round-trips without anything being dropped" do
      example = LLM.build_prompt("Some text.") |> example_json()
      decoded = JSON.decode!(example)

      {:ok, result} = LLM.extract("Some text.", llm: mock_llm(example))

      assert length(result.entities) == length(decoded["entities"])
      assert length(result.relationships) == length(decoded["relationships"])
    end
  end
end
