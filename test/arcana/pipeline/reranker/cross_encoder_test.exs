defmodule Arcana.Pipeline.Reranker.CrossEncoderTest do
  use Arcana.DataCase, async: false

  @moduletag :serving

  alias Arcana.Pipeline.Reranker.CrossEncoder

  setup_all do
    {:ok, _pid} = CrossEncoder.start_link()
    :ok
  end

  describe "rerank/3" do
    test "returns empty list for empty chunks" do
      assert {:ok, []} = CrossEncoder.rerank("anything", [], [])
    end

    test "promotes relevant chunks above irrelevant ones" do
      chunks = [
        %{id: "1", text: "Paris is the capital of France.", document_id: "d1", chunk_index: 0},
        %{
          id: "2",
          text: "The Daleks are a fictional extraterrestrial race of mutants from Doctor Who.",
          document_id: "d2",
          chunk_index: 0
        },
        %{
          id: "3",
          text: "Elixir is a functional programming language that runs on the BEAM.",
          document_id: "d3",
          chunk_index: 0
        }
      ]

      {:ok, results} = CrossEncoder.rerank("Who are the Daleks?", chunks, top_k: 3)

      assert length(results) == 3
      assert hd(results).id == "2"
    end

    test "top_k limits results" do
      chunks = [
        %{id: "1", text: "The Doctor travels through time.", document_id: "d1", chunk_index: 0},
        %{
          id: "2",
          text: "The TARDIS is bigger on the inside.",
          document_id: "d2",
          chunk_index: 0
        },
        %{
          id: "3",
          text: "Bananas are a good source of potassium.",
          document_id: "d3",
          chunk_index: 0
        }
      ]

      {:ok, results} = CrossEncoder.rerank("Doctor Who time travel", chunks, top_k: 2)

      assert length(results) == 2
    end

    test "threshold filters low-scoring chunks" do
      chunks = [
        %{
          id: "1",
          text: "The Daleks invaded Earth in the 22nd century.",
          document_id: "d1",
          chunk_index: 0
        },
        %{
          id: "2",
          text: "A recipe for chocolate cake requires eggs and flour.",
          document_id: "d2",
          chunk_index: 0
        }
      ]

      {:ok, results} = CrossEncoder.rerank("Dalek invasion", chunks, threshold: 0.0)

      assert length(results) >= 1
      assert hd(results).id == "1"
    end
  end
end
