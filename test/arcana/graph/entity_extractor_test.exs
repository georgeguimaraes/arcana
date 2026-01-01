defmodule Arcana.Graph.EntityExtractorTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.EntityExtractor

  describe "extract/1" do
    test "extracts person entities" do
      text = "Sam Altman is the CEO of OpenAI."

      entities = EntityExtractor.extract(text)

      assert Enum.any?(entities, fn e ->
               e.name == "Sam Altman" and e.type == :person
             end)
    end

    test "extracts organization entities" do
      text = "OpenAI released GPT-4 in March 2023."

      entities = EntityExtractor.extract(text)

      assert Enum.any?(entities, fn e ->
               e.name == "OpenAI" and e.type == :organization
             end)
    end

    test "extracts location entities" do
      text = "The company is headquartered in San Francisco."

      entities = EntityExtractor.extract(text)

      assert Enum.any?(entities, fn e ->
               e.name == "San Francisco" and e.type == :location
             end)
    end

    test "extracts multiple entities from text" do
      text = "Elon Musk founded SpaceX in California."

      entities = EntityExtractor.extract(text)

      assert length(entities) >= 2
    end

    test "returns entity with span positions" do
      text = "OpenAI is an AI company."

      entities = EntityExtractor.extract(text)
      openai = Enum.find(entities, fn e -> e.name == "OpenAI" end)

      assert openai.span_start == 0
      assert openai.span_end == 6
    end

    test "returns empty list for text without entities" do
      text = "This is a simple sentence without names."

      entities = EntityExtractor.extract(text)

      assert entities == []
    end

    test "handles empty text" do
      assert EntityExtractor.extract("") == []
    end

    test "deduplicates entities with same name" do
      text = "OpenAI announced that OpenAI will release a new model."

      entities = EntityExtractor.extract(text)
      openai_count = Enum.count(entities, fn e -> e.name == "OpenAI" end)

      assert openai_count == 1
    end
  end

  describe "extract_batch/1" do
    test "extracts entities from multiple texts" do
      texts = [
        "Sam Altman leads OpenAI.",
        "Elon Musk founded Tesla."
      ]

      results = EntityExtractor.extract_batch(texts)

      assert length(results) == 2
      assert is_list(hd(results))
    end
  end

  describe "label mapping" do
    test "maps PER to person" do
      assert EntityExtractor.map_label("PER") == :person
      assert EntityExtractor.map_label("B-PER") == :person
      assert EntityExtractor.map_label("I-PER") == :person
    end

    test "maps ORG to organization" do
      assert EntityExtractor.map_label("ORG") == :organization
      assert EntityExtractor.map_label("B-ORG") == :organization
    end

    test "maps LOC to location" do
      assert EntityExtractor.map_label("LOC") == :location
      assert EntityExtractor.map_label("B-LOC") == :location
    end

    test "maps MISC to concept" do
      assert EntityExtractor.map_label("MISC") == :concept
      assert EntityExtractor.map_label("B-MISC") == :concept
    end

    test "maps unknown labels to other" do
      assert EntityExtractor.map_label("UNKNOWN") == :other
      assert EntityExtractor.map_label("O") == :other
    end
  end
end
