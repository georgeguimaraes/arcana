defmodule Arcana.Graph.NERServing do
  @moduledoc """
  Lazy-loaded Nx.Serving for Named Entity Recognition using Bumblebee.

  Uses dslim/distilbert-NER which is 40% smaller than BERT-base
  while retaining 97% accuracy. Only loaded when graph features are used.
  """

  use GenServer

  @model_id "dslim/distilbert-NER"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs NER on the given text, starting the serving if not already running.
  Returns a list of entity maps with :entity, :label, :start, :end, :score.
  """
  def run(text) when is_binary(text) do
    ensure_started()

    :telemetry.span([:arcana, :graph, :ner], %{text: text}, fn ->
      result = Nx.Serving.batched_run(__MODULE__.Serving, text)
      {result, %{entity_count: length(result.entities)}}
    end)
  end

  @doc """
  Ensures the NER serving is started. Called automatically by run/1.
  """
  def ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_serving()
      _pid -> :ok
    end
  end

  @doc """
  Checks if the NER serving is currently running.
  """
  def running? do
    Process.whereis(__MODULE__.Serving) != nil
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{serving_pid: nil}}
  end

  # Private

  defp start_serving do
    # Use a global lock to prevent race conditions
    :global.trans({__MODULE__, :start}, fn ->
      case Process.whereis(__MODULE__.Serving) do
        nil -> do_start_serving()
        _pid -> :ok
      end
    end)
  end

  defp do_start_serving do
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_id})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_id})

    serving =
      Bumblebee.Text.token_classification(model_info, tokenizer,
        aggregation: :word_first,
        compile: [batch_size: 8, sequence_length: 512],
        defn_options: [compiler: EXLA]
      )

    {:ok, _pid} = Nx.Serving.start_link(serving: serving, name: __MODULE__.Serving, batch_timeout: 100)
    :ok
  end
end
