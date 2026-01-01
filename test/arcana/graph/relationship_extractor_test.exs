defmodule Arcana.Graph.RelationshipExtractorTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.RelationshipExtractor

  describe "extract/3" do
    test "extracts relationships between entities" do
      text = "Sam Altman is the CEO of OpenAI."

      entities = [
        %{name: "Sam Altman", type: :person},
        %{name: "OpenAI", type: :organization}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {
             "source": "Sam Altman",
             "target": "OpenAI",
             "type": "LEADS",
             "description": "Sam Altman serves as the CEO of OpenAI",
             "strength": 9
           }
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      assert length(relationships) == 1

      [rel] = relationships
      assert rel.source == "Sam Altman"
      assert rel.target == "OpenAI"
      assert rel.type == "LEADS"
      assert rel.description == "Sam Altman serves as the CEO of OpenAI"
      assert rel.strength == 9
    end

    test "extracts multiple relationships" do
      text = "Elon Musk founded SpaceX and acquired Twitter."

      entities = [
        %{name: "Elon Musk", type: :person},
        %{name: "SpaceX", type: :organization},
        %{name: "Twitter", type: :organization}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {
             "source": "Elon Musk",
             "target": "SpaceX",
             "type": "FOUNDED",
             "description": "Elon Musk founded SpaceX",
             "strength": 10
           },
           {
             "source": "Elon Musk",
             "target": "Twitter",
             "type": "ACQUIRED",
             "description": "Elon Musk acquired Twitter",
             "strength": 8
           }
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      assert length(relationships) == 2
      types = Enum.map(relationships, & &1.type)
      assert "FOUNDED" in types
      assert "ACQUIRED" in types
    end

    test "returns empty list when no relationships found" do
      text = "The weather is nice today."
      entities = []

      llm = fn _prompt, _context, _opts ->
        {:ok, "[]"}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)
      assert relationships == []
    end

    test "handles LLM errors gracefully" do
      text = "Some text"
      entities = [%{name: "Entity", type: :person}]

      llm = fn _prompt, _context, _opts ->
        {:error, :api_error}
      end

      assert {:error, :api_error} = RelationshipExtractor.extract(text, entities, llm)
    end

    test "handles malformed JSON response" do
      text = "Sam Altman is the CEO of OpenAI."
      entities = [%{name: "Sam Altman", type: :person}]

      llm = fn _prompt, _context, _opts ->
        {:ok, "not valid json"}
      end

      assert {:error, {:json_parse_error, _}} =
               RelationshipExtractor.extract(text, entities, llm)
    end

    test "filters out relationships with unknown entities" do
      text = "Sam Altman is the CEO of OpenAI."

      entities = [
        %{name: "Sam Altman", type: :person}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {
             "source": "Sam Altman",
             "target": "OpenAI",
             "type": "LEADS",
             "description": "Leadership role",
             "strength": 9
           }
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      # OpenAI is not in the entities list, so relationship should be filtered
      assert relationships == []
    end

    test "normalizes relationship type to uppercase" do
      text = "Sam Altman leads OpenAI."

      entities = [
        %{name: "Sam Altman", type: :person},
        %{name: "OpenAI", type: :organization}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {
             "source": "Sam Altman",
             "target": "OpenAI",
             "type": "leads",
             "description": "Leadership",
             "strength": 8
           }
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      [rel] = relationships
      assert rel.type == "LEADS"
    end

    test "clamps strength to valid range 1-10" do
      text = "Test text"

      entities = [
        %{name: "A", type: :person},
        %{name: "B", type: :person}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {"source": "A", "target": "B", "type": "KNOWS", "description": "Too high", "strength": 15},
           {"source": "B", "target": "A", "type": "KNOWS", "description": "Too low", "strength": 0}
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      strengths = Enum.map(relationships, & &1.strength)
      assert 10 in strengths
      assert 1 in strengths
    end

    test "handles missing optional fields" do
      text = "Sam Altman works at OpenAI."

      entities = [
        %{name: "Sam Altman", type: :person},
        %{name: "OpenAI", type: :organization}
      ]

      llm = fn _prompt, _context, _opts ->
        {:ok,
         """
         [
           {
             "source": "Sam Altman",
             "target": "OpenAI",
             "type": "WORKS_AT"
           }
         ]
         """}
      end

      {:ok, relationships} = RelationshipExtractor.extract(text, entities, llm)

      [rel] = relationships
      assert rel.type == "WORKS_AT"
      assert rel.description == nil
      assert rel.strength == nil
    end
  end

  describe "build_prompt/2" do
    test "includes entity names in prompt" do
      text = "Test text"

      entities = [
        %{name: "Sam Altman", type: :person},
        %{name: "OpenAI", type: :organization}
      ]

      prompt = RelationshipExtractor.build_prompt(text, entities)

      assert prompt =~ "Sam Altman"
      assert prompt =~ "OpenAI"
    end

    test "includes entity types in prompt" do
      text = "Test text"

      entities = [
        %{name: "Sam Altman", type: :person},
        %{name: "OpenAI", type: :organization}
      ]

      prompt = RelationshipExtractor.build_prompt(text, entities)

      assert prompt =~ "person"
      assert prompt =~ "organization"
    end

    test "includes input text in prompt" do
      text = "The quick brown fox jumps over the lazy dog."
      entities = [%{name: "Fox", type: :concept}]

      prompt = RelationshipExtractor.build_prompt(text, entities)

      assert prompt =~ text
    end
  end
end
