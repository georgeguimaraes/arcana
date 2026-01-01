defmodule MockRelationshipExtractor do
  @behaviour Arcana.Graph.RelationshipExtractor

  @impl true
  def extract(text, entities, opts) do
    # Simple mock: create relationships based on text content
    _llm = Keyword.get(opts, :llm)

    relationships =
      if String.contains?(text, "leads") do
        [%{source: hd(entities).name, target: List.last(entities).name, type: "LEADS"}]
      else
        []
      end

    {:ok, relationships}
  end
end

defmodule MockRelationshipExtractorWithError do
  @behaviour Arcana.Graph.RelationshipExtractor

  @impl true
  def extract(_text, _entities, _opts) do
    {:error, :extraction_failed}
  end
end

defmodule Arcana.Graph.RelationshipExtractorBehaviourTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.RelationshipExtractor

  @entities [
    %{name: "Sam Altman", type: :person},
    %{name: "OpenAI", type: :organization}
  ]

  describe "extract/3 with module extractor" do
    test "invokes module's extract callback" do
      extractor = {MockRelationshipExtractor, []}
      text = "Sam Altman leads OpenAI"

      {:ok, relationships} = RelationshipExtractor.extract(extractor, text, @entities)

      assert length(relationships) == 1
      assert hd(relationships).type == "LEADS"
    end

    test "passes options to module" do
      mock_llm = fn _prompt, _ctx, _opts -> {:ok, "[]"} end
      extractor = {MockRelationshipExtractor, llm: mock_llm}
      text = "Some text"

      {:ok, relationships} = RelationshipExtractor.extract(extractor, text, @entities)

      assert relationships == []
    end

    test "propagates errors from module" do
      extractor = {MockRelationshipExtractorWithError, []}

      assert {:error, :extraction_failed} =
               RelationshipExtractor.extract(extractor, "text", @entities)
    end
  end

  describe "extract/3 with function extractor" do
    test "invokes inline function" do
      extractor = fn _text, entities, _opts ->
        {:ok, [%{source: hd(entities).name, target: "Target", type: "RELATES_TO"}]}
      end

      {:ok, relationships} = RelationshipExtractor.extract(extractor, "text", @entities)

      assert [%{source: "Sam Altman", type: "RELATES_TO"}] = relationships
    end

    test "propagates errors from inline function" do
      extractor = fn _text, _entities, _opts ->
        {:error, :custom_error}
      end

      assert {:error, :custom_error} =
               RelationshipExtractor.extract(extractor, "text", @entities)
    end
  end

  describe "extract/3 with empty entities" do
    test "returns empty relationships for empty entities" do
      extractor = {MockRelationshipExtractor, []}

      {:ok, relationships} = RelationshipExtractor.extract(extractor, "text", [])

      assert relationships == []
    end
  end
end
