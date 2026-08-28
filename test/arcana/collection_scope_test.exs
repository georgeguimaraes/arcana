defmodule Arcana.CollectionScopeTest do
  use ExUnit.Case, async: true

  alias Arcana.CollectionScope

  describe "normalize/1" do
    test "normalizes all, one, many, and no collections" do
      assert {:ok, :all} = CollectionScope.normalize(:all)
      assert {:ok, {:only, ["a"]}} = CollectionScope.normalize("a")
      assert {:ok, {:only, ["a", "b"]}} = CollectionScope.normalize(["a", "b"])
      assert {:ok, {:only, []}} = CollectionScope.normalize([])
    end

    test "deduplicates names while preserving their order" do
      assert {:ok, {:only, ["b", "a", "c"]}} =
               CollectionScope.normalize(["b", "a", "b", "c", "a"])
    end

    test "rejects nil, blank names, and mixed lists" do
      for invalid <- [nil, "", "  ", ["a", nil], ["a", ""], [:all], {:only, ["a"]}] do
        assert {:error, {:invalid_collection_scope, ^invalid}} =
                 CollectionScope.normalize(invalid)
      end
    end
  end

  describe "from_opts/2" do
    test "normalizes every shape through the collection option" do
      assert {:ok, {:only, ["a"]}} = CollectionScope.from_opts([collection: "a"], :all)

      assert {:ok, {:only, ["a", "b"]}} =
               CollectionScope.from_opts([collection: ["a", "b"]], :all)

      assert {:ok, :all} = CollectionScope.from_opts([collection: :all], [])
      assert {:ok, {:only, []}} = CollectionScope.from_opts([collection: []], :all)
    end

    test "uses the explicit default when neither option is present" do
      assert {:ok, :all} = CollectionScope.from_opts([], :all)
      assert {:ok, {:only, []}} = CollectionScope.from_opts([], [])
    end

    test "rejects the removed plural alias instead of widening to the default" do
      assert {:error, {:unsupported_collection_option, :collections}} =
               CollectionScope.from_opts([collections: ["a"]], :all)

      assert {:error, {:unsupported_collection_option, :collections}} =
               CollectionScope.from_opts([collection: "a", collections: ["b"]], :all)
    end

    test "returns validation errors from options and defaults" do
      assert {:error, {:invalid_collection_scope, nil}} =
               CollectionScope.from_opts([collection: nil], :all)

      assert {:error, {:invalid_collection_scope, ["a", nil]}} =
               CollectionScope.from_opts([collection: ["a", nil]], :all)

      assert {:error, {:invalid_collection_scope, nil}} =
               CollectionScope.from_opts([], nil)
    end
  end

  describe "bang variants" do
    test "return normalized scopes" do
      assert {:only, ["a"]} = CollectionScope.normalize!("a")
      assert :all = CollectionScope.from_opts!([], :all)
    end

    test "raise actionable argument errors" do
      assert_raise ArgumentError, ~r/collection scope must be/, fn ->
        CollectionScope.from_opts!([collection: nil], :all)
      end

      assert_raise ArgumentError, ~r/:collections is not supported/, fn ->
        CollectionScope.from_opts!([collections: ["b"]], :all)
      end
    end
  end

  describe "intersect/2" do
    test "treats all collections as the identity" do
      scope = {:only, ["b", "a"]}

      assert scope == CollectionScope.intersect(:all, scope)
      assert scope == CollectionScope.intersect(scope, :all)
      assert :all == CollectionScope.intersect(:all, :all)
    end

    test "preserves the first scope order and never widens it" do
      assert {:only, ["c", "a"]} =
               CollectionScope.intersect(
                 {:only, ["c", "b", "a"]},
                 {:only, ["a", "c", "outside"]}
               )

      assert {:only, []} =
               CollectionScope.intersect({:only, ["a"]}, {:only, ["outside"]})

      assert {:only, []} = CollectionScope.intersect({:only, []}, :all)
    end
  end

  describe "subset?/2" do
    test "requires every explicitly requested collection to be allowed" do
      allowed = {:only, ["a", "b"]}

      assert CollectionScope.subset?({:only, ["b", "a"]}, allowed)
      assert CollectionScope.subset?({:only, []}, allowed)
      refute CollectionScope.subset?({:only, ["a", "outside"]}, allowed)
      refute CollectionScope.subset?(:all, allowed)
    end

    test "allows every scope when collections are unrestricted" do
      assert CollectionScope.subset?(:all, :all)
      assert CollectionScope.subset?({:only, ["a"]}, :all)
    end
  end
end
