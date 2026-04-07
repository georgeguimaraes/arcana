defmodule Mix.Tasks.Arcana.Graph.EmbedEntities do
  @moduledoc """
  Generates embeddings for entity descriptions.

  Entity embeddings enable GraphRAG-style entity similarity search,
  where queries are matched against entity concepts instead of relying
  on NER name extraction.

  This is automatically done during `mix arcana.graph.rebuild`, but
  can also be run separately to backfill embeddings for existing entities.

      $ mix arcana.graph.embed_entities

  ## Options

    * `--collection` - Only embed entities in the specified collection
    * `--batch-size N` - Entities per batch (default: 100)
    * `--force` - Re-embed all entities, even those with existing embeddings
    * `--quiet` - Suppress progress output

  ## Examples

      mix arcana.graph.embed_entities --collection doctor-who
      mix arcana.graph.embed_entities --force --batch-size 200

  """

  use Mix.Task

  @shortdoc "Generates embeddings for graph entity descriptions"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [quiet: :boolean, collection: :string, batch_size: :integer, force: :boolean]
      )

    quiet = Keyword.get(opts, :quiet, false)
    collection = Keyword.get(opts, :collection)
    batch_size = Keyword.get(opts, :batch_size, 100)
    force = Keyword.get(opts, :force, false)

    Mix.Task.run("app.start")

    repo = Application.get_env(:arcana, :repo)

    unless repo do
      Mix.raise("No repo configured. Set config :arcana, repo: YourApp.Repo")
    end

    unless quiet do
      Mix.shell().info(
        "Embedding entity descriptions#{if collection, do: " for '#{collection}'", else: ""}..."
      )
    end

    progress_fn =
      if quiet do
        fn _, _ -> :ok end
      else
        fn current, total ->
          if rem(current, 1000) == 0 or current == total do
            Mix.shell().info("  [#{current}/#{total}]")
          end
        end
      end

    {:ok, %{total: total}} =
      Arcana.Maintenance.embed_entities(repo,
        collection: collection,
        batch_size: batch_size,
        force: force,
        progress: progress_fn
      )

    unless quiet do
      Mix.shell().info("\nDone! Embedded #{total} entities.")
    end
  end
end
