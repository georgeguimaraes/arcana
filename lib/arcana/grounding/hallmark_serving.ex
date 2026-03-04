defmodule Arcana.Grounding.HallmarkServing do
  @moduledoc """
  Lazy-loaded NLI serving for hallucination detection via Hallmark.

  Uses Hallmark (Vectara HHEM model via Bumblebee) to score each sentence
  in the answer against the combined context. Sentences scoring below the
  threshold are marked as hallucinated.

  The model is downloaded automatically on first use via Bumblebee.
  """

  use GenServer

  alias Arcana.Grounding.{Attribution, InputFormatter, Result}

  @default_threshold 0.5

  # Client API

  @doc """
  Runs grounding analysis on the given answer against the context chunks.

  Starts the serving if not already running, then runs inference.
  Returns `{:ok, %Arcana.Grounding.Result{}}` or `{:error, reason}`.
  """
  def run(question, chunks, answer, opts \\ []) do
    ensure_started(opts)

    :telemetry.span([:arcana, :grounding], %{question: question}, fn ->
      result = GenServer.call(__MODULE__, {:run, question, chunks, answer, opts}, :infinity)

      metadata =
        case result do
          {:ok, %Result{score: score}} -> %{score: score}
          {:error, _} -> %{}
        end

      {result, metadata}
    end)
  end

  @doc """
  Ensures the serving is started. Called automatically by `run/4`.
  """
  def ensure_started(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil -> start_serving(opts)
      _pid -> :ok
    end
  end

  @doc """
  Checks if the serving is currently running.
  """
  def running? do
    Process.whereis(__MODULE__) != nil
  end

  # Server callbacks

  @impl true
  def init(opts) do
    {:ok, %{model: nil, opts: opts}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{opts: opts} = state) do
    compiler = opts[:compiler] || EXLA
    {:ok, model} = Hallmark.load(compiler: compiler)
    {:noreply, %{state | model: model}}
  end

  @impl true
  def handle_call({:run, question, chunks, answer, opts}, _from, state) do
    result = do_inference(state, question, chunks, answer, opts)
    {:reply, result, state}
  end

  # Private

  defp start_serving(opts) do
    :global.trans({__MODULE__, :start}, fn ->
      case Process.whereis(__MODULE__) do
        nil ->
          case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end

        _pid ->
          :ok
      end
    end)
  end

  defp do_inference(state, question, chunks, answer, opts) do
    %{model: model} = state
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    context = InputFormatter.format(question, chunks)

    sentences = split_sentences(answer)
    pairs = Enum.map(sentences, fn {text, _start, _end} -> {context, text} end)

    {:ok, scores} = Hallmark.score_batch(model, pairs)

    scored_sentences = Enum.zip(sentences, scores)

    hallucinated_spans =
      scored_sentences
      |> Enum.filter(fn {_sentence, score} -> score < threshold end)
      |> Enum.map(fn {{text, start, stop}, score} ->
        %{text: text, start: start, end: stop, score: 1.0 - score}
      end)
      |> Attribution.attribute(chunks)

    faithful_spans =
      scored_sentences
      |> Enum.filter(fn {_sentence, score} -> score >= threshold end)
      |> Enum.map(fn {{text, start, stop}, score} ->
        %{text: text, start: start, end: stop, score: score}
      end)
      |> Attribution.attribute(chunks)

    total_weight = sentences |> Enum.map(fn {text, _, _} -> byte_size(text) end) |> Enum.sum()

    score =
      if total_weight > 0 do
        scored_sentences
        |> Enum.map(fn {{text, _, _}, s} -> byte_size(text) * s end)
        |> Enum.sum()
        |> Kernel./(total_weight)
      else
        1.0
      end

    {:ok,
     %Result{
       score: score,
       hallucinated_spans: hallucinated_spans,
       faithful_spans: faithful_spans,
       token_labels: nil
     }}
  end

  @doc false
  def split_sentences(text) do
    # Split on sentence-ending punctuation followed by whitespace or end of string.
    # Keeps the punctuation with the sentence.
    regex = ~r/(?<=[.!?])\s+/

    parts = Regex.split(regex, text, include_captures: true)

    {sentences, _} =
      Enum.reduce(parts, {[], 0}, fn part, {acc, offset} ->
        part_bytes = byte_size(part)

        if String.trim(part) == "" do
          {acc, offset + part_bytes}
        else
          {[{part, offset, offset + part_bytes} | acc], offset + part_bytes}
        end
      end)

    Enum.reverse(sentences)
  end
end
