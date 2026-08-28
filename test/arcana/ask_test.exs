defmodule Arcana.AskTest do
  use Arcana.DataCase, async: true

  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship, RelationshipEvidence}

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

    test "an empty collection scope returns no context", %{llm: llm} do
      assert {:ok, _answer, []} =
               Arcana.ask("What are the Daleks?",
                 repo: Repo,
                 llm: llm,
                 collections: [],
                 graph: true
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

    test "does not inject a dirty community summary" do
      Repo.update_all(Community, set: [dirty: true])
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

      refute system_prompt =~ "greatest enemies"
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

  describe "ask/2 community summary ordering" do
    setup %{doc: doc} do
      collection = Repo.one!(from(c in Arcana.Collection, where: c.name == "ask-test"))
      chunk = Repo.one!(from(c in Arcana.Chunk, where: c.document_id == ^doc.id, limit: 1))

      {:ok, embedding} =
        Arcana.Embedder.embed(Arcana.Config.embedder(), "Daleks", intent: :document)

      entities =
        for name <- ~w(Daleks Skaro Davros) do
          entity =
            %Entity{}
            |> Entity.changeset(%{
              name: name,
              type: "thing",
              collection_id: collection.id,
              embedding: embedding
            })
            |> Repo.insert!()

          %EntityMention{}
          |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
          |> Repo.insert!()

          entity
        end

      ids = Enum.map(entities, & &1.id)

      community = fn summary, entity_ids ->
        %Community{}
        |> Community.changeset(%{
          level: 0,
          entity_ids: entity_ids,
          collection_id: collection.id,
          summary: summary,
          dirty: false
        })
        |> Repo.insert!()
      end

      # The issue's shape: one community holds all three matched entities,
      # several hold one each, and a hub holds one matched entity plus a
      # crowd of unrelated ones.
      #
      # ON-TOPIC is inserted LAST on purpose. Without an ORDER BY, Postgres
      # returns these in physical order on a table this small, so the best
      # community sits past the LIMIT and gets cut - which is the failure
      # the issue reports, made deterministic instead of luck.
      community.("PERIPHERAL-1", [Enum.at(ids, 0)])
      community.("PERIPHERAL-2", [Enum.at(ids, 1)])

      hub_padding = for _ <- 1..40, do: Ecto.UUID.generate()
      community.("HUB", [Enum.at(ids, 2) | hub_padding])

      community.("ON-TOPIC", ids)

      :ok
    end

    test "the most overlapping community survives the limit" do
      # Two slots, four eligible communities. Without an ORDER BY the cut is
      # arbitrary and the only community covering every matched entity can
      # lose its place to one sharing a single peripheral entity.
      put_arcana_env(:graph, community_summary_limit: 2)

      assert %{community_summaries: summaries} = graph_context()

      assert length(summaries) == 2
      assert hd(summaries) == "ON-TOPIC", "the best-overlapping community must come first"
    end

    test "a hub community loses ties to a tighter one" do
      # HUB and the peripherals each overlap one matched entity, but HUB
      # generalises over 41 entities, so it is the least useful of them.
      put_arcana_env(:graph, community_summary_limit: 3)

      assert %{community_summaries: summaries} = graph_context()

      refute "HUB" in summaries,
             "a hub community should lose a tie to a tighter one of equal overlap"
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

      document =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "Alice evidence",
          status: :completed,
          collection_id: collection.id
        })
        |> Repo.insert!()

      chunk =
        %Arcana.Chunk{}
        |> Arcana.Chunk.changeset(%{
          text: "Alice evidence",
          document_id: document.id,
          embedding: embedding
        })
        |> Repo.insert!()

      for entity <- [alice, bob, carol] do
        %EntityMention{}
        |> EntityMention.changeset(%{entity_id: entity.id, chunk_id: chunk.id})
        |> Repo.insert!()
      end

      for {source, target, type} <- [{alice, bob, "knows"}, {bob, carol, "mentors"}] do
        relationship =
          %Relationship{}
          |> Relationship.changeset(%{
            source_id: source.id,
            target_id: target.id,
            type: type
          })
          |> Repo.insert!()

        %RelationshipEvidence{}
        |> RelationshipEvidence.changeset(%{
          relationship_id: relationship.id,
          chunk_id: chunk.id
        })
        |> Repo.insert!()
      end

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

    test "graph context excludes entities supported only by incomplete documents", %{llm: llm} do
      collection = Repo.get_by!(Arcana.Collection, name: "ask-graph-depth")
      {:ok, embedding} = Arcana.Embedder.embed(Arcana.Config.embedder(), "Alice", intent: :query)

      failed =
        %Entity{}
        |> Entity.changeset(%{
          name: "Failed Alice",
          type: "person",
          collection_id: collection.id,
          embedding: embedding
        })
        |> Repo.insert!()

      document =
        %Arcana.Document{}
        |> Arcana.Document.changeset(%{
          content: "failed evidence",
          status: :failed,
          collection_id: collection.id
        })
        |> Repo.insert!()

      chunk =
        %Arcana.Chunk{}
        |> Arcana.Chunk.changeset(%{
          text: "failed evidence",
          document_id: document.id,
          embedding: embedding
        })
        |> Repo.insert!()

      %EntityMention{}
      |> EntityMention.changeset(%{entity_id: failed.id, chunk_id: chunk.id})
      |> Repo.insert!()

      graph_context = captured_graph_context(llm, [])

      assert Enum.map(graph_context.entities, & &1.name) == ["Alice"]
    end
  end
end
