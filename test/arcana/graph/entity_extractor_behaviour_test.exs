defmodule MockEntityExtractor do
  @behaviour Arcana.Graph.EntityExtractor

  @impl true
  def extract(text, opts) do
    min_score = Keyword.get(opts, :min_score, 0.0)

    all_entities = [
      %{name: "Sam Altman", type: :person, score: 0.95},
      %{name: "OpenAI", type: :organization, score: 0.98},
      %{name: "Elon Musk", type: :person, score: 0.92}
    ]

    entities =
      Enum.filter(all_entities, fn entity ->
        String.contains?(text, entity.name) and entity.score >= min_score
      end)

    {:ok, entities}
  end

  @impl true
  def extract_batch(texts, opts) do
    results = Enum.map(texts, fn text -> elem(extract(text, opts), 1) end)
    {:ok, results}
  end
end

defmodule MockEntityExtractorWithoutBatch do
  @behaviour Arcana.Graph.EntityExtractor

  @impl true
  def extract(text, _opts) do
    entities =
      [%{name: "Sam Altman", type: :person}, %{name: "Elon Musk", type: :person}]
      |> Enum.filter(&String.contains?(text, &1.name))

    {:ok, entities}
  end

  # No extract_batch implementation - should fall back to sequential
end

defmodule Arcana.Graph.EntityExtractorBehaviourTest do
  use ExUnit.Case, async: true

  alias Arcana.Graph.EntityExtractor

  describe "extract/2 with module extractor" do
    test "invokes module's extract callback" do
      extractor = {MockEntityExtractor, []}
      text = "Sam Altman leads OpenAI."

      {:ok, entities} = EntityExtractor.extract(extractor, text)

      assert length(entities) == 2
      assert Enum.any?(entities, &(&1.name == "Sam Altman"))
      assert Enum.any?(entities, &(&1.name == "OpenAI"))
    end

    test "passes options to module" do
      extractor = {MockEntityExtractor, min_score: 0.9}
      text = "OpenAI is a company."

      {:ok, entities} = EntityExtractor.extract(extractor, text)

      # MockEntityExtractor filters by min_score when option is passed
      assert Enum.all?(entities, &(&1.score >= 0.9))
    end
  end

  describe "extract/2 with function extractor" do
    test "invokes inline function" do
      extractor = fn text, _opts ->
        {:ok, [%{name: "Inline", type: :test, text: text}]}
      end

      {:ok, entities} = EntityExtractor.extract(extractor, "test input")

      assert [%{name: "Inline", text: "test input"}] = entities
    end

    test "propagates errors from inline function" do
      extractor = fn _text, _opts ->
        {:error, :extraction_failed}
      end

      assert {:error, :extraction_failed} = EntityExtractor.extract(extractor, "test")
    end
  end

  describe "extract_batch/2" do
    test "uses module's extract_batch when available" do
      extractor = {MockEntityExtractor, []}
      texts = ["Sam Altman", "Elon Musk"]

      {:ok, results} = EntityExtractor.extract_batch(extractor, texts)

      assert length(results) == 2
      assert is_list(hd(results))
    end

    test "falls back to sequential extract when extract_batch not implemented" do
      extractor = {MockEntityExtractorWithoutBatch, []}
      texts = ["Sam Altman", "Elon Musk"]

      {:ok, results} = EntityExtractor.extract_batch(extractor, texts)

      assert length(results) == 2
    end

    test "works with inline function" do
      extractor = fn text, _opts ->
        {:ok, [%{name: text, type: :test}]}
      end

      {:ok, results} = EntityExtractor.extract_batch(extractor, ["A", "B"])

      assert [[%{name: "A"}], [%{name: "B"}]] = results
    end
  end
end
