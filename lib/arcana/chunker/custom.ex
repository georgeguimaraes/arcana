defmodule Arcana.Chunker.Custom do
  @moduledoc """
  Custom chunking provider using user-provided functions.

  This module wraps a user-provided function to implement the `Arcana.Chunker`
  behaviour. It's used internally when configuring a function as the chunker.

  ## Configuration

      # Function that returns list of chunk maps
      config :arcana, chunker: fn text, opts ->
        [%{text: text, chunk_index: 0, token_count: div(String.length(text), 4)}]
      end

  The function must:
  - Accept text (string) and opts (keyword list)
  - Return a list of maps, each with `:text`, `:chunk_index`, and `:token_count`

  """

  @behaviour Arcana.Chunker

  @impl Arcana.Chunker
  def chunk(text, opts) do
    fun = Keyword.fetch!(opts, :fun)

    start_metadata = %{text_length: String.length(text)}

    :telemetry.span([:arcana, :chunk], start_metadata, fn ->
      # Pass through any additional opts (excluding :fun)
      pass_through_opts = Keyword.delete(opts, :fun)
      chunks = fun.(text, pass_through_opts)

      stop_metadata = %{chunk_count: length(chunks)}
      {chunks, stop_metadata}
    end)
  end
end
