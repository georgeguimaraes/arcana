if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.Arcana.Install do
    @shortdoc "Installs Arcana in your Phoenix application"
    @moduledoc """
    Installs Arcana in your Phoenix application.

        $ mix arcana.install

    This will:
    - Generate the migration for arcana_documents and arcana_chunks tables
    - Add the dashboard route to your Phoenix router
    - Create the Postgrex types module for pgvector
    - Configure your repo to use the types module

    If your application already defines a Postgrex types module (a
    `Postgrex.Types.define/3` call, or a `:types` key on your repo config),
    the installer skips generating one and instead tells you how to add
    the pgvector extension to your existing module.

    ## Options

      * `--no-dashboard` - Skip adding the dashboard route
      * `--repo` - The repo to use (defaults to YourApp.Repo)
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Function
    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Config

    # Files that can hold `config :app, Repo, types: ...`. config.exs alone
    # misses env files, which `import_config` pulls in but igniter's config
    # helpers don't follow.
    @config_files ["config.exs", "dev.exs", "test.exs", "prod.exs", "runtime.exs"]

    @types_define_marker "Postgrex.Types.define"

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :arcana,
        example: "mix arcana.install",
        schema: [
          dashboard: :boolean,
          repo: :string
        ],
        defaults: [dashboard: true],
        aliases: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      app_name = Igniter.Project.Application.app_name(igniter)
      app_module = app_name |> to_string() |> Macro.camelize()

      repo_module =
        if opts[:repo] do
          Module.concat([opts[:repo]])
        else
          Module.concat([app_module, "Repo"])
        end

      web_module = Module.concat([app_module <> "Web"])
      types_module = Module.concat([app_module, "PostgrexTypes"])

      {igniter, unparsable} = include_types_candidates(igniter)
      existing_types = existing_types_module(igniter, app_name, repo_module)

      igniter
      |> create_migration(repo_module)
      |> setup_postgrex_types(existing_types, app_name, repo_module, types_module)
      |> maybe_warn_unparsable(unparsable)
      |> maybe_add_dashboard_route(opts[:dashboard], web_module)
      |> Igniter.add_notice("""

      Arcana installed successfully!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Add Arcana to your supervision tree:

          children = [
            #{inspect(repo_module)},
            Arcana.Embedder.Local,
            ArcanaWeb.TaskSupervisor
          ]

         For in-memory vector store (no PostgreSQL required), also add:

            {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}

         And configure: config :arcana, vector_store: :memory

      3. (Optional) Enable telemetry logging for observability:

          # In your application's start/2, before Supervisor.start_link
          Arcana.Telemetry.Logger.attach()

         See the Telemetry guide for Prometheus/LiveDashboard integration.

      4. Start using Arcana:

          {:ok, doc} = Arcana.ingest("Your content", repo: #{inspect(repo_module)})
          {:ok, results} = Arcana.search("query", repo: #{inspect(repo_module)})
      """)
    end

    defp create_migration(igniter, repo_module) do
      repo_underscore =
        repo_module
        |> Module.split()
        |> Enum.join(".")
        |> Macro.underscore()
        |> String.replace("/", "_")

      migrations_path = Path.join(["priv", repo_underscore, "migrations"])
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_create_arcana_tables.exs"
      path = Path.join(migrations_path, filename)

      migration_content = """
      defmodule #{inspect(repo_module)}.Migrations.CreateArcanaTables do
        use Ecto.Migration

        def up do
          execute "CREATE EXTENSION IF NOT EXISTS vector"

          create table(:arcana_collections, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :name, :string, null: false
            add :description, :text

            timestamps()
          end

          create unique_index(:arcana_collections, [:name])

          create table(:arcana_documents, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :content, :text
            add :content_type, :string, default: "text/plain"
            add :source_id, :string
            add :file_path, :string
            add :metadata, :map, default: %{}
            add :status, :string, default: "pending"
            add :error, :text
            add :chunk_count, :integer, default: 0
            add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :nilify_all)

            timestamps()
          end

          create table(:arcana_chunks, primary_key: false) do
            add :id, :binary_id, primary_key: true
            add :text, :text, null: false
            add :embedding, :vector, size: 384, null: false
            add :chunk_index, :integer, default: 0
            add :token_count, :integer
            add :metadata, :map, default: %{}
            add :document_id, references(:arcana_documents, type: :binary_id, on_delete: :delete_all)

            timestamps()
          end

          create index(:arcana_chunks, [:document_id])
          create index(:arcana_documents, [:source_id])
          create index(:arcana_documents, [:collection_id])

          execute \"\"\"
          CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
          USING hnsw (embedding vector_cosine_ops)
          \"\"\"

          # Evaluation tables
          create table(:arcana_evaluation_test_cases, primary_key: false) do
            add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
            add :question, :text, null: false
            add :source, :string, null: false, default: "synthetic"
            add :source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all)

            timestamps()
          end

          create table(:arcana_evaluation_test_case_chunks, primary_key: false) do
            add :test_case_id, references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all), null: false
            add :chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false
          end

          create unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id])

          create table(:arcana_evaluation_runs, primary_key: false) do
            add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
            add :status, :string, null: false, default: "running"
            add :metrics, :map, default: %{}
            add :results, :map, default: %{}
            add :config, :map, default: %{}
            add :test_case_count, :integer, default: 0

            timestamps()
          end

          create index(:arcana_evaluation_runs, [:inserted_at])
        end

        def down do
          drop table(:arcana_evaluation_runs)
          drop table(:arcana_evaluation_test_case_chunks)
          drop table(:arcana_evaluation_test_cases)
          drop table(:arcana_chunks)
          drop table(:arcana_documents)
          drop table(:arcana_collections)
          # Note: We don't drop the vector extension as it may be used by other tables
        end
      end
      """

      Igniter.create_new_file(igniter, path, migration_content)
    end

    # Pulls only the lib/ files that actually mention Postgrex.Types.define
    # into the rewrite. Reading a file parses it eagerly, so a lib file with
    # a syntax error would otherwise abort the whole install; those are
    # collected and reported instead.
    defp include_types_candidates(igniter) do
      {igniter, unparsable} =
        igniter
        |> types_candidate_paths()
        |> Enum.reduce({igniter, []}, fn path, {igniter, unparsable} ->
          try do
            {Igniter.include_existing_file(igniter, path), unparsable}
          rescue
            _ -> {igniter, [path | unparsable]}
          end
        end)

      {igniter, Enum.reverse(unparsable)}
    end

    defp types_candidate_paths(igniter) do
      if igniter.assigns[:test_mode?] do
        igniter.assigns[:test_files]
        |> Enum.filter(fn {path, content} ->
          lib_source?(path) and String.contains?(content, @types_define_marker)
        end)
        |> Enum.map(fn {path, _content} -> path end)
      else
        "lib/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(&mentions_types_define?/1)
      end
      |> Enum.sort()
    end

    defp lib_source?(path) do
      String.starts_with?(path, "lib/") and String.ends_with?(path, ".ex")
    end

    defp mentions_types_define?(path) do
      case File.read(path) do
        {:ok, content} -> String.contains?(content, @types_define_marker)
        _ -> false
      end
    end

    defp maybe_warn_unparsable(igniter, []), do: igniter

    defp maybe_warn_unparsable(igniter, paths) do
      Igniter.add_notice(igniter, """

      Arcana could not parse these files while looking for an existing
      Postgrex types module:

      #{Enum.map_join(paths, "\n", &"    #{&1}")}

      Installation continued as if no types module existed. If one of them
      does define one, remove the module Arcana just generated and add
      Pgvector.Extensions.Vector to yours instead.
      """)
    end

    # Detects an existing Postgrex types module. The `:types` key on the repo
    # being configured is authoritative; a Postgrex.Types.define/3 call found
    # by scanning lib/ is a hint, since it may belong to a different repo.
    defp existing_types_module(igniter, app_name, repo_module) do
      configured_repo_types(igniter, app_name, repo_module) ||
        find_postgrex_types_define(igniter)
    end

    defp find_postgrex_types_define(igniter) do
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.filter(&types_define_candidate?/1)
      |> Enum.find_value(&postgrex_types_define_in_source/1)
    end

    defp types_define_candidate?(source) do
      String.ends_with?(source.path, ".ex") and
        String.contains?(Rewrite.Source.get(source, :content), @types_define_marker)
    rescue
      _ -> false
    end

    defp postgrex_types_define_in_source(source) do
      zipper = source |> Rewrite.Source.get(:quoted) |> Sourceror.Zipper.zip()

      case Function.move_to_function_call(zipper, {Postgrex.Types, :define}, :any) do
        {:ok, call} -> {:source, defined_types_module(call), source.path}
        :error -> nil
      end
    rescue
      _ -> nil
    end

    # The first argument is usually a plain alias, but `__MODULE__.Types` is a
    # common idiom (it's the one Postgrex's own docs use). Anything we can't
    # name confidently degrades to :unknown - a wrong module name in the
    # notice is worse than none.
    defp defined_types_module(call_zipper) do
      with {:ok, arg} <- Function.move_to_nth_argument(call_zipper, 0),
           {:__aliases__, _, parts} when is_list(parts) <- Sourceror.Zipper.node(arg),
           {:ok, module} <- resolve_alias(parts, arg) do
        module
      else
        _ -> :unknown
      end
    end

    defp resolve_alias(parts, zipper) do
      case Enum.split_while(parts, &is_atom/1) do
        {[_ | _] = atoms, []} -> {:ok, Module.concat(atoms)}
        {[], [{:__MODULE__, _, _} | rest]} -> resolve_self_alias(rest, zipper)
        _ -> :error
      end
    end

    defp resolve_self_alias(rest, zipper) do
      if Enum.all?(rest, &is_atom/1) do
        case enclosing_module_parts(zipper, []) do
          [] -> :error
          parts -> {:ok, Module.concat(parts ++ rest)}
        end
      else
        :error
      end
    end

    # Walks up to collect every enclosing defmodule name. Nested defmodules
    # concatenate, so `defmodule Foo do defmodule Bar` is Foo.Bar.
    defp enclosing_module_parts(zipper, acc) do
      case Sourceror.Zipper.up(zipper) do
        nil ->
          acc

        parent ->
          case Sourceror.Zipper.node(parent) do
            {:defmodule, _, [{:__aliases__, _, parts} | _]} ->
              if Enum.all?(parts, &is_atom/1) do
                enclosing_module_parts(parent, parts ++ acc)
              else
                []
              end

            _ ->
              enclosing_module_parts(parent, acc)
          end
      end
    end

    defp configured_repo_types(igniter, app_name, repo_module) do
      Enum.find_value(@config_files, fn file ->
        if Config.configures_key?(igniter, file, app_name, [repo_module, :types]) do
          {:config, file}
        end
      end)
    end

    defp setup_postgrex_types(igniter, nil, app_name, repo_module, types_module) do
      igniter
      |> create_postgrex_types_module(types_module)
      |> configure_repo_types(app_name, repo_module, types_module)
    end

    defp setup_postgrex_types(igniter, existing, app_name, repo_module, _types_module) do
      Igniter.add_notice(igniter, existing_types_notice(existing, app_name, repo_module))
    end

    defp existing_types_notice({:config, file}, _app_name, repo_module) do
      """
      #{inspect(repo_module)} already has a `:types` module configured in
      config/#{file}, so Arcana skipped generating one.

      Make sure that module includes the pgvector extension:

          Postgrex.Types.define(
            YourApp.PostgrexTypes,
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )
      """
    end

    defp existing_types_notice({:source, existing, path}, app_name, repo_module) do
      module_hint = if existing == :unknown, do: "a types module", else: inspect(existing)
      module_code = if existing == :unknown, do: "YourApp.PostgrexTypes", else: inspect(existing)

      """
      Arcana found #{module_hint} defined by a Postgrex.Types.define/3 call in
      #{path}, so it skipped generating one.

      #{inspect(repo_module)} has no `:types` key configured, so Arcana could
      not confirm this module is the one it should use - in a multi-repo app it
      may belong to a different repo. Please verify.

      If it is the right module, add the pgvector extension to it:

          Postgrex.Types.define(
            #{module_code},
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )

      and point the repo at it:

          config :#{app_name}, #{inspect(repo_module)}, types: #{module_code}

      If it belongs to a different repo, define a separate types module for
      #{inspect(repo_module)} with the same snippet and configure that instead.
      """
    end

    defp create_postgrex_types_module(igniter, types_module) do
      types_content = """
      Postgrex.Types.define(
        #{inspect(types_module)},
        [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
        []
      )
      """

      path =
        types_module
        |> Module.split()
        |> Enum.map_join("/", &Macro.underscore/1)
        |> then(&"lib/#{&1}.ex")

      Igniter.create_new_file(igniter, path, types_content, on_exists: :skip)
    end

    defp configure_repo_types(igniter, app_name, repo_module, types_module) do
      Config.configure(
        igniter,
        "config.exs",
        app_name,
        [repo_module, :types],
        {:code, Sourceror.parse_string!(inspect(types_module))}
      )
    end

    defp maybe_add_dashboard_route(igniter, false, _web_module), do: igniter

    defp maybe_add_dashboard_route(igniter, _add_dashboard, web_module) do
      router_module = Module.concat([web_module, "Router"])

      # Add the arcana_dashboard macro call in a scope
      scope_code = """
        pipe_through [:browser]

        arcana_dashboard "/arcana"
      """

      # Router discovery includes (and therefore parses) elixir files across
      # the project, so a single syntax-broken file aborts the install. The
      # dashboard route is optional - degrade to instructions instead.
      case add_dashboard_scope(igniter, router_module, scope_code) do
        {:ok, igniter} ->
          Igniter.add_notice(igniter, """

          IMPORTANT: Add this import to the top of your router (#{inspect(router_module)}):

              import ArcanaWeb.Router

          """)

        {:error, message} ->
          Igniter.add_notice(igniter, """

          Arcana could not add the dashboard route automatically: #{message}

          Add it to #{inspect(router_module)} by hand:

              import ArcanaWeb.Router

              scope "/" do
                pipe_through [:browser]

                arcana_dashboard "/arcana"
              end

          """)
      end
    end

    defp add_dashboard_scope(igniter, router_module, scope_code) do
      {:ok, Phoenix.add_scope(igniter, "/", scope_code, router: router_module)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
else
  defmodule Mix.Tasks.Arcana.Install do
    @shortdoc "Generates Arcana migrations for your application"
    @moduledoc """
    Generates the migration file needed for Arcana.

        $ mix arcana.install

    This will create a migration in your priv/repo/migrations directory
    that sets up the arcana_documents and arcana_chunks tables with
    pgvector support.

    For automatic router and config setup, add `{:igniter, "~> 0.5"}` to
    your dependencies and re-run this task.

    ## Options

      * `--repo` - The repo to generate migrations for (defaults to YourApp.Repo)
    """

    use Mix.Task

    import Mix.Generator

    @migration_template """
    defmodule <%= @repo %>.Migrations.CreateArcanaTables do
      use Ecto.Migration

      def up do
        execute "CREATE EXTENSION IF NOT EXISTS vector"

        create table(:arcana_collections, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :name, :string, null: false
          add :description, :text

          timestamps()
        end

        create unique_index(:arcana_collections, [:name])

        create table(:arcana_documents, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :content, :text
          add :content_type, :string, default: "text/plain"
          add :source_id, :string
          add :file_path, :string
          add :metadata, :map, default: %{}
          add :status, :string, default: "pending"
          add :error, :text
          add :chunk_count, :integer, default: 0
          add :collection_id, references(:arcana_collections, type: :binary_id, on_delete: :nilify_all)

          timestamps()
        end

        create table(:arcana_chunks, primary_key: false) do
          add :id, :binary_id, primary_key: true
          add :text, :text, null: false
          add :embedding, :vector, size: 384, null: false
          add :chunk_index, :integer, default: 0
          add :token_count, :integer
          add :metadata, :map, default: %{}
          add :document_id, references(:arcana_documents, type: :binary_id, on_delete: :delete_all)

          timestamps()
        end

        create index(:arcana_chunks, [:document_id])
        create index(:arcana_documents, [:source_id])
        create index(:arcana_documents, [:collection_id])

        execute \"\"\"
        CREATE INDEX arcana_chunks_embedding_idx ON arcana_chunks
        USING hnsw (embedding vector_cosine_ops)
        \"\"\"

        # Evaluation tables
        create table(:arcana_evaluation_test_cases, primary_key: false) do
          add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
          add :question, :text, null: false
          add :source, :string, null: false, default: "synthetic"
          add :source_chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :nilify_all)

          timestamps()
        end

        create table(:arcana_evaluation_test_case_chunks, primary_key: false) do
          add :test_case_id, references(:arcana_evaluation_test_cases, type: :uuid, on_delete: :delete_all), null: false
          add :chunk_id, references(:arcana_chunks, type: :uuid, on_delete: :delete_all), null: false
        end

        create unique_index(:arcana_evaluation_test_case_chunks, [:test_case_id, :chunk_id])

        create table(:arcana_evaluation_runs, primary_key: false) do
          add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
          add :status, :string, null: false, default: "running"
          add :metrics, :map, default: %{}
          add :results, :map, default: %{}
          add :config, :map, default: %{}
          add :test_case_count, :integer, default: 0

          timestamps()
        end

        create index(:arcana_evaluation_runs, [:inserted_at])
      end

      def down do
        drop table(:arcana_evaluation_runs)
        drop table(:arcana_evaluation_test_case_chunks)
        drop table(:arcana_evaluation_test_cases)
        drop table(:arcana_chunks)
        drop table(:arcana_documents)
        drop table(:arcana_collections)
        # Note: We don't drop the vector extension as it may be used by other tables
      end
    end
    """

    @impl Mix.Task
    def run(args) do
      {opts, _, _} = OptionParser.parse(args, strict: [repo: :string])

      repo = opts[:repo] || infer_repo()
      repo_underscore = Macro.underscore(repo) |> String.replace("/", "_")

      migrations_path = Path.join(["priv", repo_underscore, "migrations"])
      File.mkdir_p!(migrations_path)

      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      filename = "#{timestamp}_create_arcana_tables.exs"
      path = Path.join(migrations_path, filename)

      content = EEx.eval_string(@migration_template, assigns: [repo: repo])

      create_file(path, content)

      Mix.shell().info("""

      Arcana migration created!

      Next steps:
      1. Run the migration: mix ecto.migrate

      2. Add Arcana to your supervision tree:

          children = [
            MyApp.Repo,
            Arcana.Embedder.Local,
            ArcanaWeb.TaskSupervisor
          ]

         For in-memory vector store (no PostgreSQL required), also add:

            {Arcana.VectorStore.Memory, name: Arcana.VectorStore.Memory}

         And configure: config :arcana, vector_store: :memory

      3. Configure pgvector types in your repo config:

          config :my_app, MyApp.Repo,
            types: MyApp.PostgrexTypes

      4. Create the types module:

          # lib/my_app/postgrex_types.ex
          Postgrex.Types.define(
            MyApp.PostgrexTypes,
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )

      5. (Optional) Mount the dashboard in your router:

          # At the top of your router
          import ArcanaWeb.Router

          # In a scope with the :browser pipeline
          scope "/" do
            pipe_through [:browser]

            arcana_dashboard "/arcana"
          end

      6. (Optional) Enable telemetry logging for observability:

          # In your application's start/2, before Supervisor.start_link
          Arcana.Telemetry.Logger.attach()

         See the Telemetry guide for Prometheus/LiveDashboard integration.

      TIP: For automatic setup, add {:igniter, "~> 0.5"} to your deps
           and re-run mix arcana.install
      """)
    end

    defp infer_repo do
      case Mix.Project.config()[:app] do
        nil ->
          "MyApp.Repo"

        app ->
          app
          |> to_string()
          |> Macro.camelize()
          |> Kernel.<>(".Repo")
      end
    end
  end
end
