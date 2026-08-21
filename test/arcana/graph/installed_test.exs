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

    test "finds the table through the search_path, not just the first schema on it" do
      # The multi-tenant layout: a tenant schema first, arcana's tables in
      # public. An unqualified query resolves through the whole search_path and
      # finds the graph, so comparing against current_schema() alone reported
      # "not installed" for a database whose graph pages work.
      SQL.query!(Repo, ~s(CREATE SCHEMA IF NOT EXISTS "tenant_first"), [])
      original = SQL.query!(Repo, "SHOW search_path", []).rows |> List.flatten() |> hd()

      try do
        SQL.query!(Repo, ~s(SET search_path TO "tenant_first", public), [])

        assert SQL.query!(Repo, "SELECT count(*) FROM arcana_graph_entities", []),
               "precondition: an unqualified query still resolves the table"

        assert Arcana.Graph.installed?(Repo),
               "installed?/2 must agree with how the page's own queries resolve"
      after
        SQL.query!(Repo, "SET search_path TO #{original}", [])
      end
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
