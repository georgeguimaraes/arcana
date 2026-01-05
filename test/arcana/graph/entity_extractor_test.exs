defmodule Arcana.Graph.EntityExtractor.NERTest do
  use Arcana.DataCase, async: true

  # Requires real Bumblebee NER model - excluded in CI, run with: mix test --include serving
  @moduletag :serving

  alias Arcana.Graph.EntityExtractor.NER

  describe "extract/2" do
    test "extracts person entities" do
      text = "Sam Altman is the CEO of OpenAI."

      {:ok, entities} = NER.extract(text, [])

      assert Enum.any?(entities, fn e ->
               e.name == "Sam Altman" and e.type == "person"
             end)
    end

    test "extracts organization entities" do
      text = "OpenAI released GPT-4 in March 2023."

      {:ok, entities} = NER.extract(text, [])

      assert Enum.any?(entities, fn e ->
               e.name == "OpenAI" and e.type == "organization"
             end)
    end

    test "extracts location entities" do
      text = "The company is headquartered in San Francisco."

      {:ok, entities} = NER.extract(text, [])

      assert Enum.any?(entities, fn e ->
               e.name == "San Francisco" and e.type == "location"
             end)
    end

    test "extracts multiple entities from text" do
      text = "Elon Musk founded SpaceX in California."

      {:ok, entities} = NER.extract(text, [])

      assert length(entities) >= 2
    end

    test "returns entity with span positions" do
      text = "OpenAI is an AI company."

      {:ok, entities} = NER.extract(text, [])
      openai = Enum.find(entities, fn e -> e.name == "OpenAI" end)

      assert openai.span_start == 0
      assert openai.span_end == 6
    end

    test "returns empty list for text without entities" do
      text = "This is a simple sentence without names."

      {:ok, entities} = NER.extract(text, [])

      assert entities == []
    end

    test "handles empty text" do
      assert {:ok, []} = NER.extract("", [])
    end

    test "deduplicates entities with same name" do
      text = "OpenAI announced that OpenAI will release a new model."

      {:ok, entities} = NER.extract(text, [])
      openai_count = Enum.count(entities, fn e -> e.name == "OpenAI" end)

      assert openai_count == 1
    end
  end

  describe "extract_batch/2" do
    test "extracts entities from multiple texts" do
      texts = [
        "Sam Altman leads OpenAI.",
        "Elon Musk founded Tesla."
      ]

      {:ok, results} = NER.extract_batch(texts, [])

      assert length(results) == 2
      assert is_list(hd(results))
    end
  end

  describe "label mapping" do
    test "maps PER to person" do
      assert NER.map_label("PER") == "person"
      assert NER.map_label("B-PER") == "person"
      assert NER.map_label("I-PER") == "person"
    end

    test "maps ORG to organization" do
      assert NER.map_label("ORG") == "organization"
      assert NER.map_label("B-ORG") == "organization"
    end

    test "maps LOC to location" do
      assert NER.map_label("LOC") == "location"
      assert NER.map_label("B-LOC") == "location"
    end

    test "maps MISC to concept" do
      assert NER.map_label("MISC") == "concept"
      assert NER.map_label("B-MISC") == "concept"
    end

    test "maps unknown labels to other" do
      assert NER.map_label("UNKNOWN") == "other"
      assert NER.map_label("O") == "other"
    end
  end
end
