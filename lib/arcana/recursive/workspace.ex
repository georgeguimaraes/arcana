defmodule Arcana.Recursive.Workspace do
  @moduledoc """
  The external variable for Arcana.Recursive explorations.

  Holds full document text. The LLM navigates content via `grep/2` and
  `read_section/3` rather than embedding-based search.

  Documents are loaded upfront (from content or a DB collection) and the LLM
  sees only an overview (names, line counts). It must use tools to access the
  actual text — content is NOT stuffed into the context window.
  """

  defstruct documents: %{}

  @type document :: %{
          name: String.t(),
          text: String.t(),
          line_count: non_neg_integer()
        }

  @type t :: %__MODULE__{
          documents: %{String.t() => document()}
        }

  @doc """
  Creates an empty workspace.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Builds a workspace from content passed directly.

  Accepts a single string (stored as "doc_1") or a list of
  `%{name: String.t(), text: String.t()}` maps.
  """
  @spec from_content(String.t() | [%{name: String.t(), text: String.t()}]) :: t()
  def from_content(text) when is_binary(text) do
    doc = build_document("doc_1", text)
    %__MODULE__{documents: %{"doc_1" => doc}}
  end

  def from_content(docs) when is_list(docs) do
    documents =
      Map.new(docs, fn %{name: name, text: text} ->
        {name, build_document(name, text)}
      end)

    %__MODULE__{documents: documents}
  end

  @doc """
  Regex search across all documents in the workspace.

  Returns `{:ok, matches}` where each match has `:document`, `:line_number`,
  and `:line` fields. Case insensitive by default.

  Returns `{:error, reason}` for invalid regex patterns.
  """
  @spec grep(t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def grep(%__MODULE__{} = workspace, pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} ->
        matches =
          workspace.documents
          |> Enum.flat_map(fn {name, doc} ->
            doc.text
            |> String.split("\n")
            |> Enum.with_index(1)
            |> Enum.filter(fn {line, _num} -> Regex.match?(regex, line) end)
            |> Enum.map(fn {line, num} ->
              %{document: name, line_number: num, line: line}
            end)
          end)
          |> Enum.sort_by(&{&1.document, &1.line_number})

        {:ok, matches}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reads a range of lines from a document.

  The range is a `{start, end}` tuple (1-based, inclusive) or `:all` to
  read the entire document. Out-of-bounds ranges are clamped.

  Returns `{:error, :not_found}` for unknown document names.
  """
  @spec read_section(t(), String.t(), {pos_integer(), pos_integer()} | :all) ::
          {:ok, String.t()} | {:error, :not_found}
  def read_section(%__MODULE__{} = workspace, doc_name, range) do
    case Map.fetch(workspace.documents, doc_name) do
      {:ok, doc} ->
        {:ok, extract_lines(doc.text, range)}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns a text overview of the workspace for the LLM system prompt.

  Shows document names, line counts, and byte sizes.
  """
  @spec overview(t()) :: String.t()
  def overview(%__MODULE__{documents: docs}) when map_size(docs) == 0 do
    "Workspace is empty."
  end

  def overview(%__MODULE__{} = workspace) do
    header = "Documents in workspace:"

    entries =
      workspace.documents
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.map(fn {name, doc} ->
        bytes = byte_size(doc.text)
        "  [#{name}] #{doc.line_count} lines, #{format_bytes(bytes)}"
      end)

    Enum.join([header | entries], "\n")
  end

  @doc """
  Creates a workspace subset containing only the specified documents.

  Used by sub_explore to give a sub-agent a focused workspace.
  """
  @spec subset(t(), [String.t()]) :: t()
  def subset(%__MODULE__{} = workspace, doc_names) when is_list(doc_names) do
    name_set = MapSet.new(doc_names)

    filtered =
      workspace.documents
      |> Enum.filter(fn {name, _} -> MapSet.member?(name_set, name) end)
      |> Map.new()

    %__MODULE__{documents: filtered}
  end

  @doc "Returns the number of documents in the workspace."
  @spec document_count(t()) :: non_neg_integer()
  def document_count(%__MODULE__{documents: docs}), do: map_size(docs)

  @doc "Returns the total number of lines across all documents."
  @spec total_lines(t()) :: non_neg_integer()
  def total_lines(%__MODULE__{documents: docs}) do
    docs |> Map.values() |> Enum.sum_by(& &1.line_count)
  end

  @doc "Returns the total byte size of all documents."
  @spec total_bytes(t()) :: non_neg_integer()
  def total_bytes(%__MODULE__{documents: docs}) do
    docs |> Map.values() |> Enum.sum_by(&byte_size(&1.text))
  end

  defp build_document(name, text) do
    %{
      name: name,
      text: text,
      line_count: length(String.split(text, "\n"))
    }
  end

  defp extract_lines(text, :all), do: text

  defp extract_lines(text, {start_line, end_line}) do
    lines = String.split(text, "\n")
    total = length(lines)
    clamped_start = max(start_line, 1)
    clamped_end = min(end_line, total)

    lines
    |> Enum.slice((clamped_start - 1)..(clamped_end - 1)//1)
    |> Enum.join("\n")
  end

  defp format_bytes(bytes) when bytes >= 1024, do: "#{div(bytes, 1024)}KB"
  defp format_bytes(bytes), do: "#{bytes}B"
end
