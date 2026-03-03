defmodule Arcana.Grounding.Serving do
  @moduledoc """
  Lazy-loaded ONNX serving for LettuceDetect grounding model.

  Uses Ortex (ONNX Runtime) to run the LettuceDetect token classifier,
  which labels each token in the answer as faithful or hallucinated.

  The model and tokenizer are loaded on first use and cached in a GenServer.

  ## Configuration

      config :arcana, Arcana.Grounding.Serving,
        model_path: "priv/models/lettucedect/model.onnx"

  Export the model using `python scripts/export_lettuce_onnx.py`.
  The tokenizer is loaded from `tokenizer.json` next to the ONNX file.
  """

  use GenServer

  alias Arcana.Grounding.{Attribution, InputFormatter, Result}

  @default_max_length 512

  # Client API

  @doc """
  Runs grounding analysis on the given answer against the context chunks.

  Starts the serving if not already running, then runs inference.
  Returns `{:ok, %Arcana.Grounding.Result{}}` or `{:error, reason}`.
  """
  def run(question, chunks, answer, opts \\ []) do
    ensure_started(opts)

    :telemetry.span([:arcana, :grounding], %{question: question}, fn ->
      result = GenServer.call(__MODULE__, {:run, question, chunks, answer}, :infinity)

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
    {:ok, %{model: nil, tokenizer: nil, opts: opts}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, %{opts: opts} = state) do
    config = Application.get_env(:arcana, __MODULE__, [])
    model_path = opts[:model_path] || config[:model_path]
    tokenizer_path = opts[:tokenizer_path] || config[:tokenizer_path]

    unless model_path do
      raise """
      No model path configured for Arcana.Grounding.Serving.

      Set the path in your config:

          config :arcana, Arcana.Grounding.Serving,
            model_path: "/path/to/lettucedect/model.onnx"

      Export the model first: python scripts/export_lettuce_onnx.py
      """
    end

    # Resolve tokenizer path: either explicit, or tokenizer.json next to the ONNX file
    tokenizer_path = tokenizer_path || Path.join(Path.dirname(model_path), "tokenizer.json")

    model = Ortex.load(model_path)
    {:ok, tokenizer} = Tokenizers.Tokenizer.from_file(tokenizer_path)

    # Truncate long inputs to max model length (dynamic axes handle variable sizes)
    Tokenizers.Tokenizer.set_truncation(tokenizer, max_length: @default_max_length)

    {:noreply, %{state | model: model, tokenizer: tokenizer}}
  end

  @impl true
  def handle_call({:run, question, chunks, answer}, _from, state) do
    result = do_inference(state, question, chunks, answer)
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

  defp do_inference(state, question, chunks, answer) do
    %{model: model, tokenizer: tokenizer} = state
    context_text = InputFormatter.format(question, chunks)

    # Tokenize as pair: (context+question, answer) — native Tokenizers handles SEP insertion
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, {context_text, answer})

    input_ids =
      encoding |> Tokenizers.Encoding.get_ids() |> Nx.tensor(type: :s64) |> Nx.new_axis(0)

    attention_mask =
      encoding
      |> Tokenizers.Encoding.get_attention_mask()
      |> Nx.tensor(type: :s64)
      |> Nx.new_axis(0)

    # Run ONNX inference (ModernBERT takes input_ids + attention_mask)
    {logits} = Ortex.run(model, {input_ids, attention_mask})

    # Transfer logits off Ortex backend for post-processing (Ortex doesn't support reduce_max etc.)
    logits = Nx.backend_transfer(logits)

    # Build answer mask: tokens between first [SEP] and second [SEP] are answer tokens
    # BPE tokenizers (like ModernBERT) don't produce type_ids, so we use position-based detection
    answer_mask = build_answer_mask(encoding)

    post_process(logits, answer_mask, answer, tokenizer, chunks)
  end

  # Answer tokens sit between the first [SEP] and second [SEP] in the encoding:
  # [CLS](special) context_tokens... [SEP](special) answer_tokens... [SEP](special)
  # Count special tokens: after seeing 2 (CLS + SEP), non-special tokens are the answer.
  defp build_answer_mask(encoding) do
    special_mask = Tokenizers.Encoding.get_special_tokens_mask(encoding)

    {mask, _} =
      Enum.map_reduce(special_mask, 0, fn
        1, n -> {0, n + 1}
        0, 2 -> {1, 2}
        0, n -> {0, n}
      end)

    mask |> Nx.tensor() |> Nx.new_axis(0)
  end

  defp post_process(logits, answer_mask, answer, tokenizer, chunks) do
    probs = softmax(logits)

    # Per-token predictions: 0=faithful, 1=hallucinated
    predictions = probs |> Nx.argmax(axis: -1) |> Nx.squeeze(axes: [0]) |> Nx.to_list()
    hall_scores = probs[[0, .., 1]] |> Nx.squeeze() |> Nx.to_list()
    mask_list = answer_mask |> Nx.squeeze(axes: [0]) |> Nx.to_list()

    # Filter to answer tokens only (mask == 1)
    answer_preds =
      [mask_list, predictions, hall_scores]
      |> Enum.zip()
      |> Enum.filter(fn {mask, _pred, _score} -> mask == 1 end)
      |> Enum.map(fn {_mask, pred, score} -> {pred, score} end)

    # Get character offsets from standalone answer encoding
    {:ok, encoding} = Tokenizers.Tokenizer.encode(tokenizer, answer)
    offsets = Tokenizers.Encoding.get_offsets(encoding)
    special_mask = Tokenizers.Encoding.get_special_tokens_mask(encoding)

    content_offsets =
      Enum.zip(offsets, special_mask)
      |> Enum.reject(fn {_offset, mask} -> mask == 1 end)
      |> Enum.map(fn {offset, _} -> offset end)

    # Align predictions with offsets (use min length for safety, handles truncation)
    aligned_count = min(length(answer_preds), length(content_offsets))

    token_labels =
      Enum.zip(Enum.take(answer_preds, aligned_count), Enum.take(content_offsets, aligned_count))
      |> Enum.map(fn {{pred, score}, {start_pos, end_pos}} ->
        %{
          label: if(pred == 1, do: :hallucinated, else: :faithful),
          score: score,
          start: start_pos,
          end: end_pos,
          text: binary_slice(answer, start_pos, end_pos - start_pos)
        }
      end)

    hallucinated_spans =
      token_labels
      |> merge_hallucinated_spans(answer)
      |> Attribution.attribute(chunks)

    faithful_spans =
      token_labels
      |> merge_faithful_spans(answer)
      |> Attribution.attribute(chunks)

    faithful_count = Enum.count(token_labels, &(&1.label == :faithful))
    total = length(token_labels)
    score = if total > 0, do: faithful_count / total, else: 1.0

    {:ok,
     %Result{
       score: score,
       hallucinated_spans: hallucinated_spans,
       faithful_spans: faithful_spans,
       token_labels: token_labels
     }}
  end

  defp softmax(tensor) do
    max_val = Nx.reduce_max(tensor, axes: [-1], keep_axes: true)
    exp = Nx.exp(Nx.subtract(tensor, max_val))
    Nx.divide(exp, Nx.sum(exp, axes: [-1], keep_axes: true))
  end

  defp merge_hallucinated_spans(token_labels, answer) do
    merge_spans(token_labels, answer, :hallucinated)
  end

  defp merge_faithful_spans(token_labels, answer) do
    merge_spans(token_labels, answer, :faithful)
  end

  defp merge_spans(token_labels, answer, target_label) do
    {spans, current} =
      Enum.reduce(token_labels, {[], nil}, fn token, {spans, current} ->
        if token.label == target_label do
          case current do
            nil ->
              {spans, %{start: token.start, end: token.end, score: token.score}}

            acc ->
              {spans, %{acc | end: token.end, score: max(acc.score, token.score)}}
          end
        else
          case current do
            nil -> {spans, nil}
            acc -> {[finalize_span(acc, answer) | spans], nil}
          end
        end
      end)

    final =
      case current do
        nil -> spans
        acc -> [finalize_span(acc, answer) | spans]
      end

    Enum.reverse(final)
  end

  defp finalize_span(acc, answer) do
    %{
      text: binary_slice(answer, acc.start, acc.end - acc.start),
      start: acc.start,
      end: acc.end,
      score: acc.score
    }
  end
end
