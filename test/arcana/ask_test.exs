defmodule Arcana.AskTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Community, Entity, EntityMention}

  setup do
    {:ok, doc} =
      Arcana.ingest("The Daleks are a Skarosian species from Doctor Who.",
        repo: Repo,
        collection: "ask-test"
      )

    llm = fn prompt, _context, _opts ->
      {:ok, "Answer based on: #{String.slice(prompt, 0..50)}"}
    end

    %{doc: doc, llm: llm}
  end

  describe "ask/2" do
    test "returns answer and context", %{llm: llm} do
      {:ok, answer, context} =
        Arcana.ask("What are the Daleks?",
          repo: Repo,
          llm: llm,
          collection: "ask-test"
        )

      assert is_binary(answer)
      assert is_list(context)
      refute Enum.empty?(context)
    end

    test "errors on an unknown collection under strict_collections", %{llm: llm} do
      assert {:error, {:search_failed, {:unknown_collection, "strict-nope"}}} =
               Arcana.ask("What are the Daleks?",
                 repo: Repo,
                 llm: llm,
                 collection: "strict-nope",
                 strict_collections: true
               )
    end

    test "uses custom prompt function", %{llm: llm} do
      custom_prompt = fn _question, _context ->
        "Custom system prompt"
      end

      {:ok, answer, _} =
        Arcana.ask("What are the Daleks?",
          repo: Repo,
          llm: llm,
          collection: "ask-test",
          prompt: custom_prompt
        )

      assert is_binary(answer)
    end

    test "accepts 3-arity prompt function with graph context", %{llm: llm} do
      received = :ets.new(:received, [:set, :public])

      custom_prompt = fn _question, _context, graph_context ->
        :ets.insert(received, {:graph_context, graph_context})
        "System prompt"
      end

      {:ok, _, _} =
        Arcana.ask("What are the Daleks?",
          repo: Repo,
          llm: llm,
          collection: "ask-test",
          prompt: custom_prompt
        )

      [{:graph_context, graph_context}] = :ets.lookup(received, :graph_context)
      assert is_map(graph_context)
      :ets.delete(received)
    end
  end

  describe "ask/2 with community summaries" do
    setup %{doc: doc} do
      collection = Repo.one!(from(c in Arcana.Collection, where: c.name == "ask-test"))
      chunk = Repo.one!(from(c in Arcana.Chunk, where: c.document_id == ^doc.id, limit: 1))

      {:ok, embedding} =
        Arcana.Embedder.embed(Arcana.Config.embedder(), "Daleks", intent: :document)

      entity =
        %Entity{}
        |> Entity.changeset(%{
          name: "Daleks",
          type: "species",
          collection_id: collection.id,
          embedding: embedding
        })
        |> Repo.insert!()

      %EntityMention{}
      |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
      |> Repo.insert!()

      %Community{}
      |> Community.changeset(%{
        level: 0,
        entity_ids: [entity.id],
        collection_id: collection.id,
        summary: "The Daleks are the Doctor's greatest enemies, originating from Skaro.",
        dirty: false
      })
      |> Repo.insert!()

      %{entity: entity, collection: collection}
    end

    test "injects community summaries into the default prompt when graph enabled" do
      received = :ets.new(:received, [:set, :public])

      capturing_llm = fn _prompt, _context, opts ->
        :ets.insert(received, {:system_prompt, opts[:system_prompt]})
        {:ok, "answer"}
      end

      {:ok, _, _} =
        Arcana.ask("Who are the Daleks?",
          repo: Repo,
          llm: capturing_llm,
          collection: "ask-test",
          graph: true
        )

      [{:system_prompt, system_prompt}] = :ets.lookup(received, :system_prompt)
      :ets.delete(received)

      assert system_prompt =~ "Background knowledge:"
      assert system_prompt =~ "greatest enemies"
    end
  end

  describe "ask/2 community summary levels" do
    setup %{doc: doc} do
      collection = Repo.one!(from(c in Arcana.Collection, where: c.name == "ask-test"))
      chunk = Repo.one!(from(c in Arcana.Chunk, where: c.document_id == ^doc.id, limit: 1))

      {:ok, embedding} =
        Arcana.Embedder.embed(Arcana.Config.embedder(), "Daleks", intent: :document)

      entity =
        %Entity{}
        |> Entity.changeset(%{
          name: "Daleks",
          type: "species",
          collection_id: collection.id,
          embedding: embedding
        })
        |> Repo.insert!()

      %EntityMention{}
      |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
      |> Repo.insert!()

      for {level, summary} <- [{0, "LEVEL-ZERO-SUMMARY"}, {1, "LEVEL-ONE-SUMMARY"}] do
        %Community{}
        |> Community.changeset(%{
          level: level,
          entity_ids: [entity.id],
          collection_id: collection.id,
          summary: summary,
          dirty: false
        })
        |> Repo.insert!()
      end

      :ok
    end

    defp graph_context do
      received = :ets.new(:received, [:set, :public])

      capturing_prompt = fn _question, _context, graph_context ->
        :ets.insert(received, {:graph_context, graph_context})
        "System prompt"
      end

      {:ok, _, _} =
        Arcana.ask("Who are the Daleks?",
          repo: Repo,
          llm: fn _prompt, _context, _opts -> {:ok, "answer"} end,
          collection: "ask-test",
          graph: true,
          prompt: capturing_prompt
        )

      [{:graph_context, graph_context}] = :ets.lookup(received, :graph_context)
      :ets.delete(received)
      graph_context
    end

    test "reads only the configured level by default" do
      assert %{community_summaries: summaries} = graph_context()
      assert summaries == ["LEVEL-ZERO-SUMMARY"]
    end

    test "reads every level named by community_summary_level" do
      put_arcana_env(:graph, community_summary_level: 0..1)

      assert %{community_summaries: summaries} = graph_context()
      assert Enum.sort(summaries) == ["LEVEL-ONE-SUMMARY", "LEVEL-ZERO-SUMMARY"]
    end

    test "levels the config doesn't name stay out of the context" do
      put_arcana_env(:graph, community_summary_level: 1)

      assert %{community_summaries: ["LEVEL-ONE-SUMMARY"]} = graph_context()
    end
  end
end
