defmodule Arcana.Recursive.Tools do
  @moduledoc """
  Builds ReqLLM.Tool definitions for Arcana.Recursive explorations.

  The RLM tool set: grep, read_section, and optionally sub_explore.
  No vector search — the LLM navigates content directly.

  Tool callbacks are pass-throughs. Execution logic lives in `Arcana.Recursive`
  where it can update workspace and session state.
  """

  @doc """
  Builds the tool list for a session.

  Core tools (grep, read_section) are always included.
  sub_explore is added when depth < max_depth.
  Custom tools from opts are appended.
  """
  @spec build(keyword(), [ReqLLM.Tool.t()]) :: [ReqLLM.Tool.t()]
  def build(session_opts, custom_tools \\ []) do
    core = [grep_tool(), read_section_tool()]
    core ++ maybe_sub_explore_tool(session_opts) ++ custom_tools
  end

  defp grep_tool do
    ReqLLM.Tool.new!(
      name: "grep",
      description:
        "Search all documents for lines matching a regex pattern. " <>
          "Returns matching lines with document name and line number. " <>
          "Case insensitive. Use different patterns to explore different aspects.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Regex pattern to search for"
          }
        },
        "required" => ["pattern"]
      },
      callback: fn args -> {:ok, args} end
    )
  end

  defp read_section_tool do
    ReqLLM.Tool.new!(
      name: "read_section",
      description:
        "Read a range of lines from a specific document. " <>
          "Use grep results to identify interesting areas, then read_section to see full context. " <>
          "Line numbers are 1-based and inclusive.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "document" => %{
            "type" => "string",
            "description" => "The document name to read from"
          },
          "start_line" => %{
            "type" => "integer",
            "description" => "First line to read (1-based). Omit to read from start."
          },
          "end_line" => %{
            "type" => "integer",
            "description" => "Last line to read (inclusive). Omit to read to end."
          }
        },
        "required" => ["document"]
      },
      callback: fn args -> {:ok, args} end
    )
  end

  defp maybe_sub_explore_tool(opts) do
    depth = Keyword.get(opts, :depth, 0)
    max_depth = Keyword.get(opts, :max_depth, 3)

    if depth < max_depth, do: [sub_explore_tool()], else: []
  end

  defp sub_explore_tool do
    ReqLLM.Tool.new!(
      name: "sub_explore",
      description:
        "Spawn a focused sub-agent to analyze specific documents for a subtask. " <>
          "The sub-agent gets its own context window with only the specified documents. " <>
          "Use this to delegate focused analysis when the main task is complex.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The specific question or task for the sub-agent"
          },
          "documents" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Names of documents to give to the sub-agent"
          }
        },
        "required" => ["task", "documents"]
      },
      callback: fn args -> {:ok, args} end
    )
  end
end
