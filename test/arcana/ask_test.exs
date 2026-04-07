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

    test "accepts 3-arity prompt function with community summaries", %{llm: llm} do
      received = :ets.new(:received, [:set, :public])

      custom_prompt = fn _question, _context, communities ->
        :ets.insert(received, {:communities, communities})
        "System prompt"
      end

      {:ok, _, _} =
        Arcana.ask("What are the Daleks?",
          repo: Repo,
          llm: llm,
          collection: "ask-test",
          prompt: custom_prompt
        )

      [{:communities, communities}] = :ets.lookup(received, :communities)
      assert is_list(communities)
      :ets.delete(received)
    end
  end

  describe "ask/2 with community summaries" do
    setup %{doc: doc} do
      collection = Repo.one!(from(c in Arcana.Collection, where: c.name == "ask-test"))
      chunk = Repo.one!(from(c in Arcana.Chunk, where: c.document_id == ^doc.id, limit: 1))

      entity =
        %Entity{}
        |> Entity.changeset(%{name: "Daleks", type: "species", collection_id: collection.id})
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

    test "injects community summaries into prompt when graph enabled", %{llm: _llm} do
      received = :ets.new(:received, [:set, :public])

      capturing_llm = fn prompt, _context, _opts ->
        :ets.insert(received, {:prompt, prompt})
        {:ok, "answer"}
      end

      {:ok, _, _} =
        Arcana.ask("Who are the Daleks?",
          repo: Repo,
          llm: capturing_llm,
          collection: "ask-test",
          graph: true
        )

      [{:prompt, _prompt}] = :ets.lookup(received, :prompt)
      :ets.delete(received)
    end
  end
end
