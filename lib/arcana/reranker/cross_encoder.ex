defmodule Arcana.Reranker.CrossEncoder do
  @moduledoc """
  Local cross-encoder reranker using Bumblebee.

  Scores query-chunk pairs with a cross-encoder model, producing raw relevance
  logits. Much more accurate than bi-encoder similarity since the model sees
  the query and chunk together.

  ## Usage

      # In Arcana.Pipeline
      ctx
      |> Pipeline.search()
      |> Pipeline.rerank(reranker: Arcana.Reranker.CrossEncoder)
      |> Pipeline.answer()

      # Directly
      {:ok, reranked} = Arcana.Reranker.CrossEncoder.rerank(
        "What is Elixir?",
        chunks,
        threshold: 0.0
      )

  ## Configuration

  The serving must be started in your supervision tree:

      children = [
        {Arcana.Reranker.CrossEncoder, model: "cross-encoder/ms-marco-MiniLM-L-6-v2"}
      ]

  ## Options

    - `:model` - HuggingFace model ID (default: `cross-encoder/ms-marco-MiniLM-L-6-v2`)
    - `:threshold` - Minimum logit score to keep (default: 0.0)
    - `:top_k` - Keep top N results regardless of threshold (overrides threshold)
  """

  @behaviour Arcana.Reranker

  use GenServer

  @compile {:no_warn_undefined, [Bumblebee, Axon]}

  @default_model "cross-encoder/ms-marco-MiniLM-L-6-v2"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    unless Code.ensure_loaded?(Bumblebee) do
      raise """
      Bumblebee is required for Arcana.Reranker.CrossEncoder but not available.

      Add it and a backend to your dependencies:

          {:bumblebee, "~> 0.6"},
          {:exla, "~> 0.10"}
      """
    end

    model = Keyword.get(opts, :model, @default_model)
    sequence_length = Keyword.get(opts, :sequence_length, 512)

    {:ok, model_info} = Bumblebee.load_model({:hf, model})
    {:ok, raw_tokenizer} = Bumblebee.load_tokenizer({:hf, model})
    tokenizer = Bumblebee.configure(raw_tokenizer, length: sequence_length)

    {:ok, %{model: model_info, tokenizer: tokenizer}}
  end

  @impl Arcana.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    GenServer.call(__MODULE__, {:rerank, question, chunks, opts}, :infinity)
  end

  @impl GenServer
  def handle_call({:rerank, question, chunks, opts}, _from, state) do
    threshold = Keyword.get(opts, :threshold, 0.0)
    top_k = Keyword.get(opts, :top_k)

    pairs = Enum.map(chunks, fn chunk -> {question, chunk.text} end)
    inputs = Bumblebee.apply_tokenizer(state.tokenizer, pairs)
    %{logits: logits} = Axon.predict(state.model.model, state.model.params, inputs)
    scores = logits |> Nx.flatten() |> Nx.to_flat_list()

    scored =
      Enum.zip(chunks, scores)
      |> Enum.sort_by(fn {_chunk, score} -> score end, :desc)

    filtered =
      if top_k do
        Enum.take(scored, top_k)
      else
        Enum.filter(scored, fn {_chunk, score} -> score >= threshold end)
      end

    reranked = Enum.map(filtered, fn {chunk, score} -> Map.put(chunk, :rerank_score, score) end)

    {:reply, {:ok, reranked}, state}
  end
end
