defmodule Arcana.MixHelpersTest do
  use ExUnit.Case, async: true

  import Arcana.ConfigCase

  alias Arcana.MixHelpers

  describe "repo!/0" do
    test "returns the configured repo" do
      put_arcana_env(:repo, Arcana.TestRepo)

      assert MixHelpers.repo!() == Arcana.TestRepo
    end

    test "converts the library's ArgumentError into a clean Mix.Error" do
      # Config.repo!/1 raises ArgumentError, which the CLI would print with a
      # full stacktrace. Mix.Error prints as a single line and exits cleanly.
      assert_raise ArgumentError, fn -> Arcana.Config.repo!(embedder: :local) end

      error = assert_raise Mix.Error, fn -> MixHelpers.repo!(embedder: :local) end

      assert error.message =~ "no Ecto repo configured"
      assert error.message =~ "config :arcana, repo: MyApp.Repo"
    end
  end

  describe "detect_dimensions!/0" do
    defmodule ZeroDimensionEmbedder do
      def dimensions(_opts), do: 0
    end

    test "returns what the embedder reports" do
      put_arcana_env(:embedder, Arcana.Embedder.Local)

      assert MixHelpers.detect_dimensions!() == 384
    end

    test "raises naming the embedder when it reports an invalid dimension" do
      put_arcana_env(:embedder, ZeroDimensionEmbedder)

      error = assert_raise Mix.Error, fn -> MixHelpers.detect_dimensions!() end

      assert error.message =~ "ZeroDimensionEmbedder reported invalid embedding dimensions: 0"
      refute error.message =~ "--dimensions must be"
    end
  end

  describe "validate_dimensions!/2" do
    test "returns positive integers unchanged" do
      assert MixHelpers.validate_dimensions!(384) == 384
    end

    test "raises Mix.Error for zero, negatives and non-integers" do
      for value <- [0, -1, "384", nil] do
        assert_raise Mix.Error, ~r/--dimensions must be a positive integer/, fn ->
          MixHelpers.validate_dimensions!(value)
        end
      end
    end

    test "names the flag it was given" do
      assert_raise Mix.Error, ~r/--previous-dimensions must be a positive integer/, fn ->
        MixHelpers.validate_dimensions!(0, "--previous-dimensions")
      end
    end
  end
end
