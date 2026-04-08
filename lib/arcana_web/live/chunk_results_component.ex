defmodule ArcanaWeb.ChunkResultsComponent do
  @moduledoc """
  Shared component for rendering retrieved chunks across the Advanced,
  Pipeline, and Loop sub-tabs of the Ask dashboard.

  ## Features

  - Groups chunks by document with a compact header per document.
  - Shows document titles when available (falls back to a shortened UUID).
  - Click-to-expand details for each chunk, revealing the full text.
  - When `:grounding` is supplied, centers the snippet around the text the
    grounder cited from this chunk (instead of the first N chars).
  - Highlights chunks that the grounder used as a source.
  - Score rendered as `score: 0.0246`.

  ## Usage

      <ChunkResultsComponent.chunk_results
        chunks={@ask_context.results}
        document_titles={@ask_context.document_titles || %{}}
        grounding={Map.get(@ask_context, :grounding)}
        id="ask-chunks"
      />
  """
  use Phoenix.Component

  attr(:chunks, :list,
    required: true,
    doc: "List of chunk maps with id/text/score/document_id/chunk_index"
  )

  attr(:document_titles, :map, default: %{}, doc: "Map of document_id to display title")
  attr(:grounding, :any, default: nil, doc: "Optional %Arcana.Grounding.Result{}")
  attr(:id, :string, default: "chunk-results")

  def chunk_results(assigns) do
    assigns =
      assigns
      |> assign(:grouped, group_by_document(assigns.chunks))
      |> assign(:chunk_sources, build_chunk_source_index(assigns.grounding))

    ~H"""
    <div class="arcana-chunk-results" id={@id}>
      <%= for {doc_id, doc_chunks} <- @grouped do %>
        <section class={["arcana-chunk-doc", any_source?(doc_chunks, @chunk_sources) && "arcana-chunk-doc--has-source"]}>
          <header class="arcana-chunk-doc-header">
            <h5 class="arcana-chunk-doc-title">
              <%= if doc_id do %>
                <.link navigate={"/arcana/documents?doc=#{doc_id}"} title={"Document " <> doc_id} class="arcana-chunk-doc-link"><%= document_label(doc_id, @document_titles) %></.link>
              <% else %>
                <span title="(unknown document)"><%= document_label(doc_id, @document_titles) %></span>
              <% end %>
            </h5>
            <span class="arcana-chunk-doc-meta">
              <%= length(doc_chunks) %> <%= chunk_word(length(doc_chunks)) %>
              <%= if any_source?(doc_chunks, @chunk_sources) do %>
                <span class="arcana-chunk-source-dot" title="Cited as grounding source"></span>
              <% end %>
            </span>
          </header>
          <ul class="arcana-chunk-list">
            <%= for chunk <- doc_chunks do %>
              <li class={["arcana-chunk-item", Map.has_key?(@chunk_sources, Map.get(chunk, :id)) && "arcana-chunk-item--source"]}>
                <details class="arcana-chunk-details">
                  <summary class="arcana-chunk-summary" title={chunk_tooltip(chunk)}>
                    <span class="arcana-chunk-score">score: <%= score_str(chunk.score) %></span>
                    <span class="arcana-chunk-index">Chunk <%= chunk.chunk_index %></span>
                    <%= if graph_sources = Map.get(chunk, :graph_sources) do %>
                      <%= if is_list(graph_sources) and graph_sources != [] do %>
                        <span class="arcana-chunk-via" title={"via: " <> Enum.join(graph_sources, ", ")}>via: <%= Enum.join(graph_sources, ", ") %></span>
                      <% end %>
                    <% end %>
                    <%= if Map.has_key?(@chunk_sources, Map.get(chunk, :id)) do %>
                      <span class="arcana-chunk-supports">✓ source</span>
                    <% end %>
                    <span class="arcana-chunk-preview"><%= snippet(chunk, @chunk_sources) %></span>
                  </summary>
                  <div class="arcana-chunk-full"><%= String.trim(chunk.text || "") %></div>
                </details>
              </li>
            <% end %>
          </ul>
        </section>
      <% end %>
    </div>
    """
  end

  # --- Grouping ---

  # Sort docs by their highest-scoring chunk descending so the most
  # relevant document is rendered first.
  defp group_by_document(chunks) do
    chunks
    |> Enum.group_by(&Map.get(&1, :document_id))
    |> Enum.map(fn {doc_id, cs} -> {doc_id, Enum.sort_by(cs, & &1.score, :desc)} end)
    |> Enum.sort_by(fn {_doc_id, cs} ->
      -(cs |> Enum.map(& &1.score) |> Enum.max(fn -> 0 end))
    end)
  end

  # --- Document label resolution ---

  defp document_label(nil, _titles), do: "(unknown document)"

  defp document_label(doc_id, titles) do
    case Map.get(titles, doc_id) do
      title when is_binary(title) and title != "" -> title
      _ -> shorten_uuid(doc_id)
    end
  end

  defp shorten_uuid(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)
  defp shorten_uuid(other), do: inspect(other)

  # Native title tooltip showing the full chunk id and owning document id.
  # Falls back gracefully when either is missing (search results can lack
  # the chunk id field).
  defp chunk_tooltip(chunk) do
    [
      chunk |> Map.get(:id) |> format_tooltip_line("Chunk"),
      chunk |> Map.get(:document_id) |> format_tooltip_line("Document")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_tooltip_line(nil, _label), do: nil
  defp format_tooltip_line(id, label), do: "#{label}: #{id}"

  # --- Score formatting ---

  defp score_str(score) when is_number(score) do
    :io_lib.format("~.4f", [score * 1.0]) |> IO.iodata_to_binary()
  end

  defp score_str(_), do: "—"

  # --- Chunk count wording ---

  defp chunk_word(1), do: "chunk"
  defp chunk_word(_), do: "chunks"

  # --- Grounding source index ---

  # Builds a map of chunk_id -> list of spans that cited this chunk, so
  # downstream helpers can check membership in O(1) and pick the first
  # span to center the snippet on.
  defp build_chunk_source_index(nil), do: %{}

  defp build_chunk_source_index(%{hallucinated_spans: hs, faithful_spans: fs}) do
    (hs ++ fs)
    |> Enum.flat_map(fn span ->
      span
      |> Map.get(:sources, [])
      |> Enum.map(fn %{chunk_id: id} -> {id, span} end)
    end)
    |> Enum.group_by(fn {id, _} -> id end, fn {_, span} -> span end)
  end

  defp build_chunk_source_index(_), do: %{}

  defp any_source?(chunks, chunk_sources) do
    Enum.any?(chunks, &Map.has_key?(chunk_sources, Map.get(&1, :id)))
  end

  # --- Snippet selection ---

  @preview_window 220

  # When grounding says this chunk backed a span, find the span text in
  # the chunk and return a window centered on it. Otherwise, fall back
  # to the first N characters. The snippet always gets trimmed to drop
  # leading/trailing whitespace from the source text.
  defp snippet(chunk, chunk_sources) do
    text = String.trim(chunk.text || "")

    case Map.get(chunk_sources, Map.get(chunk, :id)) do
      [span | _] ->
        center_snippet(text, Map.get(span, :text, ""), @preview_window)

      _ ->
        head_snippet(text, @preview_window)
    end
  end

  defp head_snippet(text, window) do
    if String.length(text) > window do
      String.slice(text, 0, window) <> "..."
    else
      text
    end
  end

  defp center_snippet(text, "", window), do: head_snippet(text, window)

  defp center_snippet(text, span_text, window) do
    case :binary.match(text, span_text) do
      :nomatch ->
        head_snippet(text, window)

      {start, len} ->
        span_bytes = len
        context = max(div(window - span_bytes, 2), 0)
        snippet_start = max(0, start - context)
        snippet_end = min(byte_size(text), start + span_bytes + context)
        prefix = if snippet_start > 0, do: "...", else: ""
        suffix = if snippet_end < byte_size(text), do: "...", else: ""
        prefix <> binary_part(text, snippet_start, snippet_end - snippet_start) <> suffix
    end
  end
end
