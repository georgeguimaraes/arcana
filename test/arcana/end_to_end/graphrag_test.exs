defmodule Arcana.EndToEnd.GraphRAGTest do
  @moduledoc """
  End-to-end tests for GraphRAG functionality with real LLM APIs.

  Run with: `mix test --include end_to_end`
  Or just this file: `mix test test/arcana/end_to_end/graphrag_test.exs --include end_to_end`

  Requires ZAI_API_KEY environment variable.
  """
  use Arcana.LLMCase, async: true

  alias Arcana.Graph.{Entity, EntityMention, Relationship, CommunitySummarizer}

  # LLM calls can be slow
  @moduletag timeout: :timer.minutes(5)

  describe "GraphRAG ingestion with combined extractor" do
    @tag :end_to_end
    test "extracts entities and relationships using GraphExtractor.LLM" do
      llm = llm_config(:zai)

      text = """
      Sam Altman is the CEO of OpenAI, an artificial intelligence research company
      based in San Francisco. OpenAI was founded in 2015 by Sam Altman, Elon Musk,
      and others. The company developed GPT-4, a large language model that powers
      ChatGPT.
      """

      {:ok, document} =
        Arcana.ingest(text,
          repo: Arcana.TestRepo,
          graph: true,
          extractor: {Arcana.Graph.GraphExtractor.LLM, llm: llm},
          collection: "e2e-graphrag-test"
        )

      assert document.status == :completed

      # Verify entities were extracted
      entities = Arcana.TestRepo.all(Entity)
      entity_names = Enum.map(entities, & &1.name)

      # Should extract key entities
      assert Enum.any?(entity_names, &String.contains?(&1, "Sam Altman")) or
               Enum.any?(entity_names, &String.contains?(&1, "Altman"))

      assert Enum.any?(entity_names, &String.contains?(&1, "OpenAI"))

      # Verify entity mentions exist
      mentions = Arcana.TestRepo.all(EntityMention)
      refute Enum.empty?(mentions)

      # Verify relationships were created
      relationships = Arcana.TestRepo.all(Relationship)

      # Should have at least some relationships
      assert length(relationships) >= 1

      # Check relationship types are normalized
      for rel <- relationships do
        # Types should be UPPER_SNAKE_CASE
        assert rel.type == String.upcase(rel.type)
        assert rel.type =~ ~r/^[A-Z][A-Z0-9_]*$/
      end
    end

    @tag :end_to_end
    test "handles multiple documents in same collection" do
      llm = llm_config(:zai)

      # Ingest first document
      {:ok, doc1} =
        Arcana.ingest(
          "Anthropic is an AI safety company founded by Dario Amodei and Daniela Amodei.",
          repo: Arcana.TestRepo,
          graph: true,
          extractor: {Arcana.Graph.GraphExtractor.LLM, llm: llm},
          collection: "e2e-multi-doc-test"
        )

      # Ingest second document about related topic
      {:ok, doc2} =
        Arcana.ingest(
          "Dario Amodei previously worked at OpenAI before founding Anthropic.",
          repo: Arcana.TestRepo,
          graph: true,
          extractor: {Arcana.Graph.GraphExtractor.LLM, llm: llm},
          collection: "e2e-multi-doc-test"
        )

      assert doc1.status == :completed
      assert doc2.status == :completed

      # Both documents should contribute entities
      entities = Arcana.TestRepo.all(Entity)
      entity_names = Enum.map(entities, & &1.name)

      # Should have entities from both documents
      assert Enum.any?(entity_names, &String.contains?(&1, "Anthropic"))
      assert Enum.any?(entity_names, &String.contains?(&1, "Dario")) or
               Enum.any?(entity_names, &String.contains?(&1, "Amodei"))
    end
  end

  describe "GraphRAG search with ask" do
    setup do
      llm = llm_config(:zai)

      # Ingest test document with graph
      {:ok, _doc} =
        Arcana.ingest(
          """
          Elixir is a functional programming language created by José Valim in 2011.
          It runs on the Erlang VM (BEAM) and is designed for building scalable,
          fault-tolerant applications. Phoenix is a popular web framework built with Elixir.
          LiveView allows building real-time features without JavaScript.
          """,
          repo: Arcana.TestRepo,
          graph: true,
          extractor: {Arcana.Graph.GraphExtractor.LLM, llm: llm},
          collection: "e2e-ask-test"
        )

      %{llm: llm}
    end

    @tag :end_to_end
    test "answers questions using graph-enhanced search", %{llm: llm} do
      {:ok, answer, results} =
        Arcana.ask("Who created Elixir?",
          repo: Arcana.TestRepo,
          llm: llm,
          graph: true,
          entity_extractor: fn query, _opts ->
            if query =~ "Elixir" do
              {:ok, [%{name: "Elixir", type: :technology}]}
            else
              {:ok, []}
            end
          end,
          collection: "e2e-ask-test"
        )

      assert is_binary(answer)
      assert String.length(answer) > 10
      refute Enum.empty?(results)

      # Answer should mention José Valim
      answer_lower = String.downcase(answer)
      assert answer_lower =~ "josé" or answer_lower =~ "valim" or answer_lower =~ "2011"
    end

    @tag :end_to_end
    test "combines vector and graph results", %{llm: llm} do
      {:ok, answer, results} =
        Arcana.ask("What is Phoenix and how does it relate to Elixir?",
          repo: Arcana.TestRepo,
          llm: llm,
          graph: true,
          entity_extractor: fn query, _opts ->
            entities = []
            entities = if query =~ "Phoenix", do: [%{name: "Phoenix", type: :technology} | entities], else: entities
            entities = if query =~ "Elixir", do: [%{name: "Elixir", type: :technology} | entities], else: entities
            {:ok, entities}
          end,
          collection: "e2e-ask-test"
        )

      assert is_binary(answer)
      refute Enum.empty?(results)

      # Answer should mention the relationship
      answer_lower = String.downcase(answer)
      assert answer_lower =~ "phoenix" or answer_lower =~ "framework" or answer_lower =~ "elixir"
    end
  end

  describe "Community summarization" do
    @tag :end_to_end
    test "generates community summary from entities and relationships" do
      llm = llm_config(:zai)

      entities = [
        %{name: "Sam Altman", type: :person, description: "CEO of OpenAI"},
        %{name: "OpenAI", type: :organization, description: "AI research company"},
        %{name: "GPT-4", type: :technology, description: "Large language model"}
      ]

      relationships = [
        %{source: "Sam Altman", target: "OpenAI", type: "LEADS", description: "CEO role"},
        %{source: "OpenAI", target: "GPT-4", type: "DEVELOPED", description: "Created the model"}
      ]

      # Use LLM.complete format
      llm_fn = fn prompt, _context, opts ->
        Arcana.LLM.complete(llm, prompt, [], opts)
      end

      {:ok, summary} = CommunitySummarizer.summarize(entities, relationships, llm_fn)

      assert is_binary(summary)
      assert String.length(summary) > 20

      # Summary should mention key entities
      summary_lower = String.downcase(summary)
      assert summary_lower =~ "openai" or summary_lower =~ "sam" or summary_lower =~ "altman"
    end

    @tag :end_to_end
    test "handles complex community with many entities" do
      llm = llm_config(:zai)

      entities = [
        %{name: "Google", type: :organization, description: "Tech company"},
        %{name: "DeepMind", type: :organization, description: "AI lab"},
        %{name: "Demis Hassabis", type: :person, description: "CEO of DeepMind"},
        %{name: "AlphaGo", type: :technology, description: "Go-playing AI"},
        %{name: "AlphaFold", type: :technology, description: "Protein structure prediction AI"},
        %{name: "Gemini", type: :technology, description: "Large language model"}
      ]

      relationships = [
        %{source: "Google", target: "DeepMind", type: "OWNS", description: "Acquired in 2014"},
        %{source: "Demis Hassabis", target: "DeepMind", type: "LEADS"},
        %{source: "DeepMind", target: "AlphaGo", type: "DEVELOPED"},
        %{source: "DeepMind", target: "AlphaFold", type: "DEVELOPED"},
        %{source: "Google", target: "Gemini", type: "DEVELOPED"}
      ]

      llm_fn = fn prompt, _context, opts ->
        Arcana.LLM.complete(llm, prompt, [], opts)
      end

      {:ok, summary} = CommunitySummarizer.summarize(entities, relationships, llm_fn)

      assert is_binary(summary)
      # Should produce a meaningful summary that captures the essence
      assert String.length(summary) > 50

      summary_lower = String.downcase(summary)
      # Should mention key themes
      assert summary_lower =~ "google" or summary_lower =~ "deepmind" or
               summary_lower =~ "ai" or summary_lower =~ "artificial intelligence"
    end
  end

  describe "Full GraphRAG pipeline" do
    @tag :end_to_end
    test "complete flow: ingest, build graph, search, ask" do
      llm = llm_config(:zai)

      # 1. Ingest with GraphRAG
      {:ok, document} =
        Arcana.ingest(
          """
          Rust is a systems programming language that emphasizes safety and performance.
          It was created by Graydon Hoare at Mozilla Research. Rust has no garbage collector
          and uses a borrow checker for memory safety. Popular projects using Rust include
          Firefox, Dropbox, and Cloudflare Workers.
          """,
          repo: Arcana.TestRepo,
          graph: true,
          extractor: {Arcana.Graph.GraphExtractor.LLM, llm: llm},
          collection: "e2e-full-pipeline"
        )

      assert document.status == :completed

      # 2. Verify graph was built
      entities = Arcana.TestRepo.all(Entity)
      refute Enum.empty?(entities)

      entity_names = Enum.map(entities, & &1.name)
      assert Enum.any?(entity_names, &String.contains?(&1, "Rust"))

      # 3. Search with graph enhancement
      {:ok, search_results} =
        Arcana.search("What is Rust?",
          repo: Arcana.TestRepo,
          graph: true,
          entity_extractor: fn _q, _opts ->
            {:ok, [%{name: "Rust", type: :technology}]}
          end,
          collection: "e2e-full-pipeline"
        )

      refute Enum.empty?(search_results)

      # 4. Ask questions
      {:ok, answer, _results} =
        Arcana.ask("Who created Rust and what are its main features?",
          repo: Arcana.TestRepo,
          llm: llm,
          graph: true,
          entity_extractor: fn _q, _opts ->
            {:ok, [%{name: "Rust", type: :technology}]}
          end,
          collection: "e2e-full-pipeline"
        )

      assert is_binary(answer)
      answer_lower = String.downcase(answer)

      # Should mention key facts
      assert answer_lower =~ "mozilla" or answer_lower =~ "graydon" or
               answer_lower =~ "safety" or answer_lower =~ "memory"
    end
  end
end
