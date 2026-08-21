defmodule Arcana.Graph.InstalledTest do
  @moduledoc """
  Covers the check the dashboard uses to decide whether the Graph page can run.

  The graph tables ship on their own migration version, so skipping
  `Arcana.Graph.Migration.up/1` is a supported install - and before this the
  dashboard mounted the Graph page anyway and raised
  `relation "arcana_graph_entities" does not exist`.
  """
  use Arcana.DataCase, async: true

  alias Ecto.Adapters.SQL

  describe "installed?/2" do
    test "is true where the graph tables were migrated" do
      assert Arcana.Graph.installed?(Repo)
    end

    test "is false in a schema that has no graph tables" do
      # A schema rather than a dropped table: this suite's own graph tests need
      # arcana_graph_entities to exist, and dropping it here would take them
      # with it. An empty schema is the same question asked somewhere harmless.
      SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "graph_absent"), [])

      refute Arcana.Graph.installed?(Repo, prefix: "graph_absent")
    end

    test "is false for a schema that does not exist at all" do
      refute Arcana.Graph.installed?(Repo, prefix: "no_such_schema_here")
    end

    test "does not confuse another table in the same schema for the graph" do
      SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "graph_decoy"), [])

      SQL.query!(
        Repo,
        "CREATE TABLE IF NOT EXISTS \"graph_decoy\".arcana_documents (id int)",
        []
      )

      refute Arcana.Graph.installed?(Repo, prefix: "graph_decoy"),
             "presence of some arcana table is not presence of the graph schema"
    end
  end
end
