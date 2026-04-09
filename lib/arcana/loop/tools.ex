defmodule Arcana.Loop.Tools do
  @moduledoc """
  Default tool definitions and execution for `Arcana.Loop`.

  Tools are exposed to the controller LLM as `ReqLLM.Tool` structs. The
  callbacks on those structs are placeholders: the loop runner executes
  tools itself via `execute/4` so it can mutate the loop state (accumulate
  chunks, record history, terminate the loop).

  ## Default toolset

  | Tool      | What it does                                                |
  |-----------|-------------------------------------------------------------|
  | `search`  | Search the knowledge base. Uses graph data when available. |
  | `answer`  | Provide the final answer (terminates the loop).            |
  | `give_up` | Admit defeat and stop (terminates the loop).               |

  Terminating tools (`answer` and `give_up`) end the loop. `search` is the
  only tool that touches your Repo and the only one that accumulates state.

  Query rewriting and decomposition aren't separate tools — they happen
  inside the `search` tool's `query` parameter, guided by the system prompt.

  ## Custom tools

  Pass `tools: [...]` to `Loop.run/2` with your own `ReqLLM.Tool` structs
  appended to (or replacing) the defaults. Custom tools are invoked via
  their `:callback` function when the controller calls them.

  The callback is a 1-arity function `(args) -> {:ok, text} | {:error, text}`
  where `text` is the string returned to the controller as the tool result.
  Custom tools always continue the loop (they never terminate it). The
  controller can still call `answer` or `give_up` to end the loop.

      web_search = ReqLLM.Tool.new!(
        name: "web_search",
        description: "Search the web for current information.",
        parameter_schema: [query: [type: :string, required: true]],
        callback: fn %{query: q} ->
          case MyApp.WebSearch.run(q) do
            {:ok, results} -> {:ok, format_results(results)}
            {:error, reason} -> {:error, inspect(reason)}
          end
        end
      )

      Loop.run(ctx, tools: Tools.default() ++ [web_search], controller_llm: llm)
  """

  alias Arcana.Loop.Context
  alias ReqLLM.Tool

  @no_op_callback {__MODULE__, :no_op_callback}

  @doc """
  Returns the default list of tool definitions as `ReqLLM.Tool` structs.

  These are the tools shipped with `Arcana.Loop`. Pass `tools: default/0`
  (or omit `:tools`) to use them. Replace with your own list to customize.

  ## Context-aware search tool

  When called with a list of collection names longer than one, the
  `search` tool gains an optional `collection` parameter that the
  controller can use to narrow the search per call. When called with
  no collections, `[nil]`, or a single-element list, the parameter is
  omitted and the caller-supplied collection (if any) is always used.

  That way, `Arcana.Loop.new(collection: "docs")` locks the controller
  to a single collection programmatically (the tool can't even express
  a different one), while `Arcana.Loop.new(collections: ["a", "b"])`
  lets the controller pick per call.
  """
  @spec default(collections :: [String.t() | nil]) :: [Tool.t()]
  def default(collections \\ [nil]) do
    [
      search_tool(collections),
      answer_tool(),
      give_up_tool()
    ]
  end

  @doc false
  # Placeholder callback for ReqLLM.Tool. The loop runner executes tools
  # itself via execute/3 so it can read and update the loop state. This is
  # only here to satisfy ReqLLM.Tool.new!'s callback validation.
  def no_op_callback(_args), do: {:ok, nil}

  # When caller supplies 2+ collections, let the controller pick per call
  # via a `collection` param. Otherwise the collection is either fixed
  # (single) or unconstrained (nil), and there's nothing for the tool to
  # choose.
  defp search_tool(collections) when is_list(collections) and length(collections) > 1 do
    choices = Enum.map_join(collections, ", ", &inspect/1)

    Tool.new!(
      name: "search",
      description: """
      Search the knowledge base for chunks relevant to a query. Returns up to
      a few chunk summaries with stable IDs and similarity scores. Uses graph
      enhanced retrieval automatically when the collection has a knowledge
      graph.

      This corpus is split across multiple collections. Use the `collection`
      argument to narrow the search to one of them when a question is clearly
      about a single topic. Omit `collection` to search across all of them.
      Available collections: #{choices}.

      Use this when you need information from the corpus to answer the user's
      question. Do not use it for general knowledge questions that do not
      require the corpus, and do not call it twice with the same query.
      """,
      parameter_schema: [
        query: [
          type: :string,
          required: true,
          doc: "The search query. Should be a focused phrase or question, not just keywords."
        ],
        collection: [
          type: :string,
          doc:
            "Optional. Restrict the search to a single collection. Must be one of: #{choices}. Omit to search all."
        ],
        limit: [
          type: :pos_integer,
          default: 5,
          doc:
            "Maximum chunks to return. Keep low (3 to 5) unless gathering comprehensive context."
        ]
      ],
      callback: @no_op_callback
    )
  end

  defp search_tool(_single_or_none) do
    Tool.new!(
      name: "search",
      description: """
      Search the knowledge base for chunks relevant to a query. Returns up to
      a few chunk summaries with stable IDs and similarity scores. Uses graph
      enhanced retrieval automatically when the collection has a knowledge
      graph.

      Use this when you need information from the corpus to answer the user's
      question. Do not use it for general knowledge questions that do not
      require the corpus, and do not call it twice with the same query.
      """,
      parameter_schema: [
        query: [
          type: :string,
          required: true,
          doc: "The search query. Should be a focused phrase or question, not just keywords."
        ],
        limit: [
          type: :pos_integer,
          default: 5,
          doc:
            "Maximum chunks to return. Keep low (3 to 5) unless gathering comprehensive context."
        ]
      ],
      callback: @no_op_callback
    )
  end

  defp answer_tool do
    Tool.new!(
      name: "answer",
      description: """
      Provide the final answer to the user's question. Calling this tool ends
      the conversation. The `text` argument is what the user will see.

      Call this as soon as the chunks you already have are sufficient to
      answer the question, even if a few details could in principle be
      sharpened by another search. Synthesis from imperfect chunks is the
      expected mode of operation, not a fallback.

      Do not call this on the very first turn before any retrieval.
      """,
      parameter_schema: [
        text: [
          type: :string,
          required: true,
          doc: "The complete final answer the user will see."
        ]
      ],
      callback: @no_op_callback
    )
  end

  defp give_up_tool do
    Tool.new!(
      name: "give_up",
      description: """
      Stop trying when the question cannot be answered from the knowledge
      base. Calling this tool ends the conversation. Use this after several
      good-faith attempts have failed.
      """,
      parameter_schema: [
        reason: [
          type: :string,
          required: true,
          doc: "A short explanation of why the question cannot be answered."
        ]
      ],
      callback: @no_op_callback
    )
  end

  @doc """
  Executes a tool call against the loop context.

  Returns one of:

    * `{:continue, updated_ctx, summary_text, meta}` - the loop should
      continue; `summary_text` is what gets sent back to the controller
      LLM as the tool result, and `meta` is a map of extra metadata to
      record in the tool history (e.g. `%{returned_chunk_ids: [...]}`
      for search).
    * `{:terminate, updated_ctx, reason, answer_text}` - the loop should
      stop; `reason` is one of `:answered` or `:gave_up`; `answer_text`
      becomes `ctx.answer`.
  """
  @spec execute(Context.t(), String.t(), map(), keyword()) ::
          {:continue, Context.t(), String.t(), map()}
          | {:terminate, Context.t(), atom(), String.t()}
  def execute(ctx, name, args, opts \\ [])

  def execute(%Context{} = ctx, "search", args, _opts) when not is_map_key(args, :query) do
    {:continue, ctx, "search error: missing :query argument", %{returned_chunk_ids: []}}
  end

  def execute(%Context{} = ctx, "search", %{query: query} = args, opts) do
    limit = Map.get(args, :limit, 5)

    case resolve_search_collection(ctx.collections, Map.get(args, :collection)) do
      {:error, message} ->
        {:continue, ctx, "search error: #{message}", %{returned_chunk_ids: []}}

      {:ok, collection_opts} ->
        search_opts =
          [repo: ctx.repo, limit: limit]
          |> Keyword.merge(collection_opts)
          |> Keyword.merge(Keyword.get(opts, :search_opts, []))

        search_fn = Keyword.get(opts, :search_fn, &Arcana.search/2)

        case search_fn.(query, search_opts) do
          {:ok, chunks} ->
            chunk_cap = Keyword.get(opts, :chunk_cap, 30)
            new_ctx = accumulate_chunks(ctx, chunks, chunk_cap)
            returned_ids = Enum.map(chunks, &chunk_id/1)

            {:continue, new_ctx, format_search_summary(chunks),
             %{returned_chunk_ids: returned_ids}}

          {:error, reason} ->
            {:continue, ctx, "search error: #{inspect(reason)}", %{returned_chunk_ids: []}}
        end
    end
  end

  def execute(%Context{} = ctx, "answer", %{text: text}, _opts) do
    {:terminate, ctx, :answered, text}
  end

  def execute(%Context{} = ctx, "give_up", %{reason: reason}, _opts) do
    {:terminate, ctx, :gave_up, "Could not answer: #{reason}"}
  end

  def execute(%Context{} = ctx, name, args, opts) do
    tools = Keyword.get(opts, :tools, [])

    case find_tool(tools, name) do
      nil ->
        {:continue, ctx, "Unknown tool: #{name}", %{}}

      tool ->
        case invoke_callback(tool.callback, args) do
          {:ok, text} when is_binary(text) ->
            {:continue, ctx, text, %{}}

          {:error, text} when is_binary(text) ->
            {:continue, ctx, "Tool error: #{text}", %{}}

          text when is_binary(text) ->
            {:continue, ctx, text, %{}}

          other ->
            {:continue, ctx, "Tool returned unexpected value: #{inspect(other)}", %{}}
        end
    end
  end

  defp find_tool(tools, name) do
    Enum.find(tools, fn tool ->
      tool.name == name or to_string(tool.name) == name
    end)
  end

  defp invoke_callback({mod, fun}, args), do: apply(mod, fun, [args])
  defp invoke_callback(fun, args) when is_function(fun, 1), do: fun.(args)

  # Resolves which collection(s) a search call should run against.
  #
  # The loop context carries an allowed list. The tool call may optionally
  # pass a `collection` arg. The resolution table:
  #
  #   ctx.collections    tool arg    result
  #   [nil]              nil         unconstrained
  #   [nil]              "x"         collection: "x" (no restriction to validate against)
  #   [single]           nil         collection: single
  #   [single]           _           collection: single (arg ignored, lock wins)
  #   [a, b]             nil         collections: [a, b]
  #   [a, b]             "a"         collection: "a"
  #   [a, b]             "c"         error: not in allowed list
  defp resolve_search_collection(ctx_collections, tool_arg)

  defp resolve_search_collection([nil], nil), do: {:ok, []}
  defp resolve_search_collection([nil], name) when is_binary(name), do: {:ok, [collection: name]}

  defp resolve_search_collection([single], _arg) when is_binary(single),
    do: {:ok, [collection: single]}

  defp resolve_search_collection(list, nil) when is_list(list),
    do: {:ok, [collections: list]}

  defp resolve_search_collection(list, name) when is_list(list) and is_binary(name) do
    if name in list do
      {:ok, [collection: name]}
    else
      {:error,
       "collection #{inspect(name)} is not in the allowed list (#{Enum.map_join(list, ", ", &inspect/1)})"}
    end
  end

  defp accumulate_chunks(%Context{chunks: existing} = ctx, new_chunks, chunk_cap) do
    merged =
      (existing ++ new_chunks)
      |> Enum.uniq_by(&chunk_id/1)
      |> Enum.sort_by(&chunk_score/1, :desc)
      |> Enum.take(chunk_cap)

    %{ctx | chunks: merged}
  end

  defp chunk_id(%{id: id}), do: id
  defp chunk_id(%{"id" => id}), do: id
  defp chunk_id(other), do: other

  defp chunk_score(%{score: score}) when is_number(score), do: score
  defp chunk_score(%{"score" => score}) when is_number(score), do: score
  defp chunk_score(_), do: 0.0

  defp format_search_summary([]), do: "No results."

  # Pass full chunk text to the controller, not truncated previews. The model
  # is the answerer in this loop and it needs to see the actual evidence to
  # decide whether the chunks already answer the question. Truncated previews
  # caused over-search: the model never felt confident enough to commit and
  # kept refining queries instead. The chunk_cap on accumulated chunks
  # bounds the answerer's working memory; this format only governs what one
  # tool result contains.
  defp format_search_summary(chunks) do
    top = Enum.take(chunks, 5)

    formatted =
      top
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {chunk, i} ->
        id = chunk_id(chunk)
        text = chunk_text(chunk)
        "#{i}. [#{id}]\n#{text}"
      end)

    "Found #{length(chunks)} chunks. Top #{length(top)}:\n\n#{formatted}"
  end

  defp chunk_text(%{text: text}) when is_binary(text), do: text
  defp chunk_text(%{"text" => text}) when is_binary(text), do: text
  defp chunk_text(_), do: ""
end
