defmodule Mix.Tasks.InstallerBranchesTest do
  @moduledoc """
  Both installers are `if Code.ensure_loaded?(Igniter) do ... else ... end`,
  and Igniter is always loaded in the test environment. That means the
  `else` module is never compiled here, so a private helper defined only in
  the Igniter branch and called from the fallback is invisible to every
  other test and to CI, while breaking the install for anyone without
  Igniter.

  These tests read the source instead of running it.
  """
  use ExUnit.Case, async: true

  @installers [
    "lib/mix/tasks/arcana.install.ex",
    "lib/mix/tasks/arcana.graph.install.ex"
  ]

  defp fallback_branch(path) do
    source = File.read!(path)
    start = :binary.match(source, "\nelse\n")

    assert start != :nomatch, "#{path} should have an Igniter fallback branch"
    {offset, length} = start

    binary_part(source, offset + length, byte_size(source) - offset - length)
  end

  test "the fallback branch defines every private helper it calls" do
    for path <- @installers do
      branch = fallback_branch(path)

      called =
        ~r/(?<!defp )\b([a-z_][a-z0-9_]*)\(/
        |> Regex.scan(branch)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      defined =
        ~r/defp?\s+([a-z_][a-z0-9_]*)[\s(]/
        |> Regex.scan(branch)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      # Only the helpers this refactor introduced; everything else is either
      # a stdlib call or defined elsewhere in the fallback module.
      for helper <- ["migration_contents"] do
        if MapSet.member?(called, helper) do
          assert MapSet.member?(defined, helper),
                 "#{path}: the fallback branch calls #{helper}/n but never defines it, " <>
                   "so installing without Igniter fails to compile"
        end
      end
    end
  end

  test "the fallback branch is valid Elixir on its own" do
    for path <- @installers do
      branch = fallback_branch(path)

      # Drop the `if`'s own closing `end`.
      source = branch |> String.trim_trailing() |> String.replace_suffix("end", "")

      assert {:ok, _ast} = Code.string_to_quoted(source),
             "#{path}: the fallback branch does not parse"
    end
  end
end
