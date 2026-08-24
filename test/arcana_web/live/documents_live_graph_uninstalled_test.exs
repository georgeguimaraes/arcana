defmodule ArcanaWeb.DocumentsLiveGraphUninstalledTest do
  @moduledoc """
  The Build Graph button on a database where the graph was never migrated.

  This is the combination the earlier graph-page work missed: `enabled?/0` reads
  config while `installed?/0` reads the schema, and the button renders on the
  config flag. So an app that configures GraphRAG but skips
  `Arcana.Graph.Migration.up/1` shows the button, and clicking it used to spin
  forever - `Arcana.Graph.build_and_persist/4` raised 42P01 inside a supervised
  task that is not linked to the LiveView, so the crash took the task down
  silently, `{:graph_complete, _}` never arrived, and `graph_indexing` stayed
  true with no error anywhere the user could see.

  `async: false` so the sandbox is shared and the LiveView uses this test's
  connection; renaming the table is DDL inside the test transaction, so the
  rollback puts it back.
  """
  use ArcanaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Arcana.ConfigCase, only: [put_arcana_env: 2]

  alias Ecto.Adapters.SQL

  setup do
    # Ingest before enabling the graph and before hiding the table: with the
    # graph enabled, Arcana.ingest/2 builds one too, so seeding in the other
    # order fails in setup for the very reason the test is about.
    {:ok, doc} = Arcana.ingest("Elixir runs on the BEAM virtual machine.", repo: Repo)

    put_arcana_env(:graph, enabled: true)

    SQL.query!(
      Repo,
      "ALTER TABLE arcana_graph_entities RENAME TO arcana_graph_entities_hidden",
      []
    )

    %{doc: doc}
  end

  test "precondition: graph reads as enabled but not installed" do
    assert Arcana.Graph.enabled?(), "the button renders off this flag"
    refute Arcana.Graph.installed?(Repo), "and the schema is what is missing"
  end

  test "clicking Build Graph reports the missing schema", %{conn: conn, doc: doc} do
    {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

    html = render_hook(view, "build_graph", %{})

    assert html =~ "GraphRAG is not installed"
    assert Process.alive?(view.pid)
  end

  test "the spinner does not get stuck on", %{conn: conn, doc: doc} do
    # The actual regression. A flash is nice, but what broke the page was
    # graph_indexing staying true with nothing left to clear it.
    {:ok, view, _html} = live(conn, "/arcana/documents?doc=#{doc.id}")

    render_hook(view, "build_graph", %{})

    refute render(view) =~ "Building...",
           "graph_indexing must not be left on after a failed build"
  end
end
