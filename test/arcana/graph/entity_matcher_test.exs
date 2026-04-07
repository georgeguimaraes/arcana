defmodule Arcana.Graph.EntityMatcherTest do
  use Arcana.DataCase, async: true

  alias Arcana.Collection
  alias Arcana.Graph.Entity
  alias Arcana.Graph.EntityMatcher

  describe "behaviour" do
    test "defines match/3 callback" do
      assert {:match, 3} in EntityMatcher.behaviour_info(:callbacks)
    end
  end

  describe "Embedding matcher" do
    alias Arcana.Graph.EntityMatcher.Embedding

    test "implements EntityMatcher behaviour" do
      assert Embedding.module_info(:attributes)[:behaviour] == [EntityMatcher]
    end

    test "returns empty list when there are no entities" do
      collection = create_collection("matcher-empty-#{System.unique_integer([:positive])}")

      assert {:ok, []} =
               Embedding.match("anything", [collection.id], repo: Repo, threshold: 0.0)
    end

    test "filters out entities below threshold" do
      collection =
        create_collection("matcher-threshold-#{System.unique_integer([:positive])}")

      # Entity with embedding that won't match anything semantically
      _entity =
        create_entity_with_embedding(collection, "Random", random_unit_vector())

      # An impossibly high threshold should match nothing
      assert {:ok, []} =
               Embedding.match("a query", [collection.id], repo: Repo, threshold: 0.999999)
    end

    test "returns entity ids when matches exist above threshold" do
      collection =
        create_collection("matcher-match-#{System.unique_integer([:positive])}")

      # Create entity with a fixed embedding, then query with the same embedding
      vec = random_unit_vector()
      entity = create_entity_with_embedding(collection, "Doctor", vec)

      # Inject our own embedder that returns this exact vector
      with_embedder(fn _text -> {:ok, vec} end, fn ->
        assert {:ok, [id]} =
                 Embedding.match("the Doctor", [collection.id],
                   repo: Repo,
                   threshold: 0.5
                 )

        assert id == entity.id
      end)
    end

    test "respects :limit option" do
      collection =
        create_collection("matcher-limit-#{System.unique_integer([:positive])}")

      vec = random_unit_vector()

      for n <- 1..5 do
        create_entity_with_embedding(collection, "Entity-#{n}", vec)
      end

      with_embedder(fn _text -> {:ok, vec} end, fn ->
        assert {:ok, ids} =
                 Embedding.match("query", [collection.id],
                   repo: Repo,
                   threshold: 0.0,
                   limit: 2
                 )

        assert length(ids) == 2
      end)
    end
  end

  describe "NER matcher" do
    alias Arcana.Graph.EntityMatcher.NER

    test "implements EntityMatcher behaviour" do
      assert NER.module_info(:attributes)[:behaviour] == [EntityMatcher]
    end

    test "returns empty list when extractor finds no entities" do
      extractor = fn _text, _opts -> {:ok, []} end

      assert {:ok, []} =
               NER.match("ignored", nil, repo: Repo, entity_extractor: extractor)
    end

    test "looks up extracted names in the entities table" do
      collection = create_collection("ner-lookup-#{System.unique_integer([:positive])}")

      alice = create_entity(collection, "Alice", "person")
      _bob = create_entity(collection, "Bob", "person")

      extractor = fn _text, _opts ->
        {:ok, [%{name: "Alice", type: "person"}]}
      end

      assert {:ok, ids} =
               NER.match("about Alice", [collection.id],
                 repo: Repo,
                 entity_extractor: extractor
               )

      assert ids == [alice.id]
    end

    test "scopes lookups to the given collection_ids" do
      target = create_collection("ner-target-#{System.unique_integer([:positive])}")
      other = create_collection("ner-other-#{System.unique_integer([:positive])}")

      target_alice = create_entity(target, "Alice", "person")
      _other_alice = create_entity(other, "Alice", "person")

      extractor = fn _text, _opts ->
        {:ok, [%{name: "Alice", type: "person"}]}
      end

      assert {:ok, [id]} =
               NER.match("about Alice", [target.id],
                 repo: Repo,
                 entity_extractor: extractor
               )

      assert id == target_alice.id
    end

    test "ignores entities the extractor doesn't find" do
      collection =
        create_collection("ner-missing-#{System.unique_integer([:positive])}")

      _alice = create_entity(collection, "Alice", "person")

      extractor = fn _text, _opts ->
        {:ok, [%{name: "Charlie", type: "person"}]}
      end

      assert {:ok, []} =
               NER.match("about Charlie", [collection.id],
                 repo: Repo,
                 entity_extractor: extractor
               )
    end
  end

  describe "Arcana.Config.parse_entity_matcher_config/1" do
    alias Arcana.Config

    test "expands :embedding shortcut" do
      assert Config.parse_entity_matcher_config(:embedding) ==
               {EntityMatcher.Embedding, []}
    end

    test "expands :ner shortcut" do
      assert Config.parse_entity_matcher_config(:ner) == {EntityMatcher.NER, []}
    end

    test "expands {:embedding, opts} shortcut" do
      assert Config.parse_entity_matcher_config({:embedding, threshold: 0.5}) ==
               {EntityMatcher.Embedding, [threshold: 0.5]}
    end

    test "passes through bare module" do
      assert Config.parse_entity_matcher_config(EntityMatcher.NER) ==
               {EntityMatcher.NER, []}
    end

    test "passes through {module, opts}" do
      assert Config.parse_entity_matcher_config({MyApp.Custom, threshold: 0.7}) ==
               {MyApp.Custom, [threshold: 0.7]}
    end
  end

  # Helpers

  defp create_collection(name) do
    %Collection{}
    |> Collection.changeset(%{name: name})
    |> Repo.insert!()
  end

  defp create_entity(collection, name, type) do
    %Entity{}
    |> Entity.changeset(%{name: name, type: type, collection_id: collection.id})
    |> Repo.insert!()
  end

  defp create_entity_with_embedding(collection, name, embedding) do
    %Entity{}
    |> Entity.changeset(%{
      name: name,
      type: "concept",
      collection_id: collection.id,
      embedding: embedding
    })
    |> Repo.insert!()
  end

  defp random_unit_vector(dims \\ 384) do
    raw = for _ <- 1..dims, do: :rand.uniform() - 0.5
    norm = :math.sqrt(Enum.reduce(raw, 0.0, fn x, acc -> acc + x * x end))
    Enum.map(raw, &(&1 / norm))
  end

  # Temporarily swap the embedder for the duration of `fun` so the test
  # doesn't depend on Bumblebee being loaded.
  defp with_embedder(fun_embed, test_fun) do
    original = Application.get_env(:arcana, :embedder)
    Application.put_env(:arcana, :embedder, fun_embed)

    try do
      test_fun.()
    after
      if original do
        Application.put_env(:arcana, :embedder, original)
      else
        Application.delete_env(:arcana, :embedder)
      end
    end
  end
end
