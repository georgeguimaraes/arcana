defmodule Arcana.ConfigTest do
  # async: false because some tests touch Application env
  use ExUnit.Case, async: false

  alias Arcana.Config

  describe "get/2" do
    test "returns value from opts" do
      assert Config.get([repo: :my_repo], :repo) == :my_repo
    end

    test "falls back to app env when opt is missing" do
      original = Application.get_env(:arcana, :test_key)
      on_exit(fn -> Application.put_env(:arcana, :test_key, original) end)

      Application.put_env(:arcana, :test_key, :from_env)
      assert Config.get([], :test_key) == :from_env
    end

    test "opts take precedence over app env" do
      original = Application.get_env(:arcana, :test_key)
      on_exit(fn -> Application.put_env(:arcana, :test_key, original) end)

      Application.put_env(:arcana, :test_key, :from_env)
      assert Config.get([test_key: :from_opts], :test_key) == :from_opts
    end

    test "returns nil when neither opts nor env have the key" do
      assert Config.get([], :nonexistent_key_xyz) == nil
    end
  end

  describe "merge_app_opts/2" do
    test "returns opts as-is when no global config" do
      assert Config.merge_app_opts([limit: 5], :nonexistent_namespace_xyz) == [limit: 5]
    end

    test "merges global config with per-call opts" do
      original = Application.get_env(:arcana, :test_namespace)
      on_exit(fn -> Application.put_env(:arcana, :test_namespace, original) end)

      Application.put_env(:arcana, :test_namespace, limit: 10, mode: :vector)
      result = Config.merge_app_opts([], :test_namespace)
      assert Keyword.equal?(result, limit: 10, mode: :vector)
    end

    test "per-call opts override global config" do
      original = Application.get_env(:arcana, :test_namespace)
      on_exit(fn -> Application.put_env(:arcana, :test_namespace, original) end)

      Application.put_env(:arcana, :test_namespace, limit: 10, mode: :vector)
      result = Config.merge_app_opts([limit: 99], :test_namespace)
      assert result[:limit] == 99
      assert result[:mode] == :vector
    end
  end

  describe "reranker/1" do
    test "returns nil when no reranker is configured anywhere" do
      original = Application.get_env(:arcana, :reranker)
      on_exit(fn -> Application.put_env(:arcana, :reranker, original) end)
      Application.delete_env(:arcana, :reranker)

      assert Config.reranker([]) == nil
    end

    test "returns nil when explicitly disabled per-call" do
      original = Application.get_env(:arcana, :reranker)
      on_exit(fn -> Application.put_env(:arcana, :reranker, original) end)
      Application.put_env(:arcana, :reranker, SomeModule)

      assert Config.reranker(reranker: false) == nil
    end

    test "uses per-call reranker over global" do
      original = Application.get_env(:arcana, :reranker)
      on_exit(fn -> Application.put_env(:arcana, :reranker, original) end)
      Application.put_env(:arcana, :reranker, GlobalReranker)

      assert Config.reranker(reranker: PerCallReranker) == {PerCallReranker, []}
    end

    test "falls back to global reranker when not in opts" do
      original = Application.get_env(:arcana, :reranker)
      on_exit(fn -> Application.put_env(:arcana, :reranker, original) end)
      Application.put_env(:arcana, :reranker, GlobalReranker)

      assert Config.reranker([]) == {GlobalReranker, []}
    end

    test "preserves opts when reranker is a {module, opts} tuple" do
      assert Config.reranker(reranker: {SomeReranker, over_fetch: 5}) ==
               {SomeReranker, [over_fetch: 5]}
    end

    test "wraps a 3-arity function as the reranker" do
      fun = fn _q, chunks, _opts -> {:ok, chunks} end
      assert {^fun, []} = Config.reranker(reranker: fun)
    end
  end

  describe "parse_embedder_config/1" do
    test "expands :local shortcut to module" do
      assert Config.parse_embedder_config(:local) == {Arcana.Embedder.Local, []}
    end

    test "expands {:local, opts} shortcut" do
      assert Config.parse_embedder_config({:local, model: "x"}) ==
               {Arcana.Embedder.Local, [model: "x"]}
    end

    test "expands :openai shortcut" do
      assert Config.parse_embedder_config(:openai) == {Arcana.Embedder.OpenAI, []}
    end

    test "wraps a 1-arity function in Embedder.Custom" do
      fun = fn _text -> {:ok, [0.0]} end
      assert Config.parse_embedder_config(fun) == {Arcana.Embedder.Custom, [fun: fun]}
    end

    test "passes through bare module" do
      assert Config.parse_embedder_config(MyApp.Embedder) == {MyApp.Embedder, []}
    end

    test "passes through {module, opts} tuple" do
      assert Config.parse_embedder_config({MyApp.Embedder, key: 1}) ==
               {MyApp.Embedder, [key: 1]}
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/invalid embedding config/, fn ->
        Config.parse_embedder_config("not valid")
      end
    end
  end

  describe "parse_chunker_config/1" do
    test "expands :default shortcut to Chunker.Default" do
      assert Config.parse_chunker_config(:default) == {Arcana.Chunker.Default, []}
    end

    test "expands {:default, opts} shortcut" do
      assert Config.parse_chunker_config({:default, chunk_size: 256}) ==
               {Arcana.Chunker.Default, [chunk_size: 256]}
    end

    test "wraps a 2-arity function in Chunker.Custom" do
      fun = fn _text, _opts -> [] end
      assert Config.parse_chunker_config(fun) == {Arcana.Chunker.Custom, [fun: fun]}
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/invalid chunker config/, fn ->
        Config.parse_chunker_config(123)
      end
    end
  end

  describe "parse_pdf_parser_config/1" do
    test "expands :poppler shortcut" do
      assert Config.parse_pdf_parser_config(:poppler) ==
               {Arcana.FileParser.PDF.Poppler, []}
    end

    test "expands {:poppler, opts} shortcut" do
      assert Config.parse_pdf_parser_config({:poppler, timeout: 5000}) ==
               {Arcana.FileParser.PDF.Poppler, [timeout: 5000]}
    end

    test "passes through bare module" do
      assert Config.parse_pdf_parser_config(MyApp.PDF) == {MyApp.PDF, []}
    end
  end

  describe "parse_reranker_config/1" do
    test "returns nil for nil" do
      assert Config.parse_reranker_config(nil) == nil
    end

    test "returns nil for false" do
      assert Config.parse_reranker_config(false) == nil
    end

    test "wraps bare module" do
      assert Config.parse_reranker_config(MyReranker) == {MyReranker, []}
    end

    test "passes through {module, opts}" do
      assert Config.parse_reranker_config({MyReranker, threshold: 0.5}) ==
               {MyReranker, [threshold: 0.5]}
    end

    test "wraps a 3-arity function (no custom module)" do
      fun = fn _q, _chunks, _opts -> {:ok, []} end
      assert Config.parse_reranker_config(fun) == {fun, []}
    end
  end
end
