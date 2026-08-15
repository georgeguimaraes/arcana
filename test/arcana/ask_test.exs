defmodule Arcana.AskTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship}

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

  # Runs ask/2 against the "ask-graph-depth" collection with an arity-3
  # prompt that captures the graph context handed to it.
  defp captured_graph_context(llm, opts) do
    received = :ets.new(:received, [:set, :public])

    prompt = fn _question, _context, graph_context ->
      :ets.insert(received, {:graph_context, graph_context})
      "System prompt"
    end

    base_opts = [
      repo: Arcana.TestRepo,
      llm: llm,
      collection: "ask-graph-depth",
      graph: true,
      prompt: prompt
    ]

    {:ok, _, _} = Arcana.ask("Alice", Keyword.merge(base_opts, opts))

    [{:graph_context, graph_context}] = :ets.lookup(received, :graph_context)
    :ets.delete(received)
    graph_context
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

  describe "ask/2 with graph_depth" do
    setup do
      collection =
        %Arcana.Collection{}
        |> Arcana.Collection.changeset(%{name: "ask-graph-depth"})
        |> Repo.insert!()

      # Only Alice gets an embedding, so only Alice matches the question.
      {:ok, embedding} = Arcana.Embedder.embed(Arcana.Config.embedder(), "Alice", intent: :query)

      alice =
        %Entity{}
        |> Entity.changeset(%{
          name: "Alice",
          type: "person",
          collection_id: collection.id,
          embedding: embedding
        })
        |> Repo.insert!()

      bob =
        %Entity{}
        |> Entity.changeset(%{name: "Bob", type: "person", collection_id: collection.id})
        |> Repo.insert!()

      carol =
        %Entity{}
        |> Entity.changeset(%{name: "Carol", type: "person", collection_id: collection.id})
        |> Repo.insert!()

      %Relationship{}
      |> Relationship.changeset(%{
        source_id: alice.id,
        target_id: bob.id,
        type: "knows"
      })
      |> Repo.insert!()

      %Relationship{}
      |> Relationship.changeset(%{
        source_id: bob.id,
        target_id: carol.id,
        type: "mentors"
      })
      |> Repo.insert!()

      llm = fn _prompt, _context, _opts -> {:ok, "answer"} end

      %{llm: llm}
    end

    test "source_id scopes graph context, not just chunks", %{llm: llm} do
      # Alice is mentioned in src-a, her neighbour Bob only in src-b.
      # Asking within src-a must not leak Bob's edge into the prompt.
      collection = Repo.get_by!(Arcana.Collection, name: "ask-graph-depth")
      alice = Repo.get_by!(Entity, name: "Alice", collection_id: collection.id)
      bob = Repo.get_by!(Entity, name: "Bob", collection_id: collection.id)

      for {entity, source} <- [{alice, "src-a"}, {bob, "src-b"}] do
        document =
          %Arcana.Document{}
          |> Arcana.Document.changeset(%{
            content: "doc for #{source}",
            source_id: source,
            status: :completed,
            collection_id: collection.id
          })
          |> Repo.insert!()

        chunk =
          %Arcana.Chunk{}
          |> Arcana.Chunk.changeset(%{
            text: "chunk for #{source}",
            document_id: document.id,
            embedding: Enum.map(1..384, fn _ -> 0.1 end)
          })
          |> Repo.insert!()

        %EntityMention{}
        |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
        |> Repo.insert!()
      end

      graph_context = captured_graph_context(llm, graph_depth: 1, source_id: "src-a")

      assert [%{name: "Alice"}] = graph_context.entities
      assert graph_context.relationships == []
    end

    test "depth 0 keeps relationships restricted to matched entities", %{llm: llm} do
      graph_context = captured_graph_context(llm, [])

      assert [%{name: "Alice"}] = graph_context.entities
      assert graph_context.relationships == []
    end

    test "depth 1 includes edges from matched entities to their neighbors", %{llm: llm} do
      graph_context = captured_graph_context(llm, graph_depth: 1)

      assert [%{name: "Alice"}] = graph_context.entities
      assert [%{source: "Alice", target: "Bob", type: "knows"}] = graph_context.relationships
    end

    test "depth 2 includes the two-hop path edges", %{llm: llm} do
      graph_context = captured_graph_context(llm, graph_depth: 2)

      types = graph_context.relationships |> Enum.map(& &1.type) |> Enum.sort()
      assert types == ["knows", "mentors"]
    end
  end
end
