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

  # Imported or auto-imported: present in the branch without a local def.
  defp known_names do
    MapSet.new(~w(
      def defp defmodule defmacro do end fn case cond if unless with for
      quote unquote use import alias require raise throw try rescue catch
      after else when in and or not
      to_string inspect is_nil is_binary is_list is_map is_atom length
      hd tl elem tuple_size map_size byte_size
    ))
    |> MapSet.union(imported_names())
  end

  # Imported explicitly by the fallback modules. Listed rather than parsed
  # so a new import has to be looked at instead of silently widening what
  # this test will accept.
  defp imported_names do
    # import Mix.Generator
    MapSet.new(~w(create_file create_directory copy_file copy_template embed_text embed_template))
  end

  test "the fallback branch defines every private helper it calls" do
    for path <- @installers do
      branch = fallback_branch(path)

      # Unqualified calls only. A lookbehind for `.` keeps Mix.shell() and
      # Calendar.strftime() out, which otherwise arrive as "shell" and
      # "strftime" and look like missing local helpers.
      called =
        ~r/(?<![.\w:])([a-z_][a-z0-9_]*)\(/
        |> Regex.scan(branch)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      defined =
        ~r/defp?\s+([a-z_][a-z0-9_]*)[\s(]/
        |> Regex.scan(branch)
        |> Enum.map(fn [_, name] -> name end)
        |> MapSet.new()

      # Every unqualified call the branch makes and doesn't define itself.
      # Module-qualified calls (Mix.raise, OptionParser.parse) never match
      # the regex, and the kernel/stdlib names below come from elsewhere by
      # definition.
      missing = called |> MapSet.difference(defined) |> MapSet.difference(known_names())

      assert MapSet.size(missing) == 0,
             "#{path}: the fallback branch calls " <>
               "#{inspect(Enum.sort(missing))} without defining it, so installing " <>
               "without Igniter fails to compile"
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
