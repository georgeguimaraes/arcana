defmodule Arcana.Agent.Reranker.CrossEncoder do
  @moduledoc """
  Local cross-encoder reranker using Bumblebee.

  Scores query-chunk pairs with a cross-encoder model, producing raw relevance
  logits. Much more accurate than bi-encoder similarity since the model sees
  the query and chunk together.

  ## Usage

      # In Agent pipeline
      ctx
      |> Agent.search()
      |> Agent.rerank(reranker: Arcana.Agent.Reranker.CrossEncoder)
      |> Agent.answer()

      # Directly
      {:ok, reranked} = Arcana.Agent.Reranker.CrossEncoder.rerank(
        "What is Elixir?",
        chunks,
        threshold: 0.0
      )

  ## Configuration

  The serving must be started in your supervision tree:

      children = [
        {Arcana.Agent.Reranker.CrossEncoder, model: "cross-encoder/ms-marco-MiniLM-L-6-v2"}
      ]

  ## Options

    - `:model` - HuggingFace model ID (default: `cross-encoder/ms-marco-MiniLM-L-6-v2`)
    - `:threshold` - Minimum logit score to keep (default: 0.0)
    - `:top_k` - Keep top N results regardless of threshold (overrides threshold)
  """

  @behaviour Arcana.Agent.Reranker

  @default_model "cross-encoder/ms-marco-MiniLM-L-6-v2"

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)

    {:ok, model_info} = Bumblebee.load_model({:hf, model})

    sequence_length = Keyword.get(opts, :sequence_length, 512)

    {:ok, tokenizer} =
      Bumblebee.load_tokenizer({:hf, model})
      |> then(fn {:ok, t} -> {:ok, Bumblebee.configure(t, length: sequence_length)} end)

    # Store model info for direct inference
    :persistent_term.put({__MODULE__, :model}, model_info)
    :persistent_term.put({__MODULE__, :tokenizer}, tokenizer)

    # Use a simple GenServer-free approach: tokenize and predict directly
    {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
  end

  @impl Arcana.Agent.Reranker
  def rerank(_question, [], _opts), do: {:ok, []}

  def rerank(question, chunks, opts) do
    threshold = Keyword.get(opts, :threshold, 0.0)
    top_k = Keyword.get(opts, :top_k)

    model_info = :persistent_term.get({__MODULE__, :model})
    tokenizer = :persistent_term.get({__MODULE__, :tokenizer})

    pairs = Enum.map(chunks, fn chunk -> {question, chunk.text} end)
    inputs = Bumblebee.apply_tokenizer(tokenizer, pairs)
    %{logits: logits} = Axon.predict(model_info.model, model_info.params, inputs)
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

    {:ok, Enum.map(filtered, fn {chunk, _score} -> chunk end)}
  end
end
