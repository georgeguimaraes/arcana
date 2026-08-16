defmodule Mix.Tasks.Arcana.Gen.EmbeddingMigrationTest do
  use ExUnit.Case, async: true

  import Arcana.ConfigCase
  import ExUnit.CaptureIO

  alias Mix.Tasks.Arcana.Gen.EmbeddingMigration

  # The task used to read `Application.get_env(:arcana, repo)` — the wrong
  # otp_app, since a host app configures `config :my_app, MyApp.Repo` — and
  # fall back to a hardcoded "priv/repo". Both repos below land somewhere
  # else than that, and the expectations come from
  # Mix.EctoSQL.source_repo_priv/1, the function `mix ecto.migrate`
  # resolves migrations through.
  #
  # They hang off their own otp_app, not :arcana: Arcana.Config.repo!/1
  # raises when it finds more than one repo key in the :arcana app env, so
  # registering them there would break whichever async test is scanning.
  @otp_app :arcana_embedding_migration_test

  defmodule EmbeddingDefaultPrivRepo do
    use Ecto.Repo, otp_app: :arcana_embedding_migration_test, adapter: Ecto.Adapters.Postgres
  end

  defmodule CustomPrivRepo do
    use Ecto.Repo, otp_app: :arcana_embedding_migration_test, adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    Application.put_env(@otp_app, CustomPrivRepo, priv: "priv/embedding_migration_custom_priv")

    on_exit(fn -> Application.delete_env(@otp_app, CustomPrivRepo) end)
    :ok
  end

  # What the old code produced for every repo, whatever it was called.
  @legacy_migrations_path "priv/repo/migrations"

  setup do
    on_exit(fn ->
      # Both the correct destination and the one the old path builder
      # picked, so a failing run leaves no stray file behind.
      for repo <- [EmbeddingDefaultPrivRepo, CustomPrivRepo] do
        File.rm_rf!(ecto_migrations_path(repo))
      end

      Enum.each(generated_migration(@legacy_migrations_path), &File.rm!/1)
    end)

    :ok
  end

  defp ecto_migrations_path(repo) do
    repo
    |> Mix.EctoSQL.source_repo_priv()
    |> Path.relative_to_cwd()
    |> Path.join("migrations")
  end

  defp generated_migration(dir) do
    Path.wildcard(Path.join(dir, "*_update_embedding_dimensions.exs"))
  end

  # --dimensions and --previous-dimensions keep the run off the embedder
  # and off the database, so only the path resolution is under test.
  defp generate(repo) do
    put_arcana_env(:repo, repo)

    capture_io(fn ->
      EmbeddingMigration.run(["--dimensions", "512", "--previous-dimensions", "768"])
    end)
  end

  test "writes the migration where ecto.migrate reads it" do
    generate(EmbeddingDefaultPrivRepo)

    assert [path] = generated_migration(ecto_migrations_path(EmbeddingDefaultPrivRepo))
    assert File.read!(path) =~ "size: 512"
    assert generated_migration(@legacy_migrations_path) == []
  end

  test "honors a repo with a configured :priv" do
    dir = ecto_migrations_path(CustomPrivRepo)
    assert dir == "priv/embedding_migration_custom_priv/migrations"

    generate(CustomPrivRepo)

    assert [_path] = generated_migration(dir)
    assert generated_migration(@legacy_migrations_path) == []
  end

  test "creates the HNSW index via raw SQL with the opclass, not Ecto options" do
    content = EmbeddingMigration.migration_content(1024)

    assert content =~ "size: 1024"

    assert content =~ "CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks"
    assert content =~ "USING hnsw (embedding vector_cosine_ops)"

    # The old form rendered :options as a WITH (...) clause, which Postgres rejects
    refute content =~ ~s|options: "vector_cosine_ops"|
    refute content =~ "using: :hnsw"
    refute content =~ "create index("
  end

  test "drops the install migration's index name, plus the Ecto default defensively" do
    content = EmbeddingMigration.migration_content(768)

    assert content =~ ~s|execute "DROP INDEX IF EXISTS arcana_chunks_embedding_idx"|
    assert content =~ ~s|execute "DROP INDEX IF EXISTS arcana_chunks_embedding_index"|

    # The old drop targeted the Ecto-default name and silently matched nothing
    refute content =~ "drop_if_exists index("
  end

  test "generated migration is valid Elixir" do
    assert {:ok, _ast} = Code.string_to_quoted(EmbeddingMigration.migration_content(512))
    assert {:ok, _ast} = Code.string_to_quoted(EmbeddingMigration.migration_content(512, 1024))
  end

  test "down restores the previous dimensions, not a hardcoded 384" do
    content = EmbeddingMigration.migration_content(1024, 768)

    [up, down] = String.split(content, "def down do")

    assert up =~ "modify :embedding, :vector, size: 1024"
    assert down =~ "modify :embedding, :vector, size: 768"
    refute down =~ "size: 384"
  end

  test "down raises instead of truncating when the previous dimensions are unknown" do
    content = EmbeddingMigration.migration_content(1024)

    [_up, down] = String.split(content, "def down do")

    assert down =~ "raise \"Set the previous vector size"
    # The old template silently rewrote any column back to 384
    refute down =~ ~r/^\s+modify :embedding/m
  end
end
