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

    If the repo already has a `:types` key in its config, the installer
    leaves it alone and tells you how to add the pgvector extension to that
    module.

    A `Postgrex.Types.define/3` call found by scanning `lib/` is a weaker
    signal: types modules are per-repo, and nothing in the call says which
    repo it serves. The installer leaves that module untouched and generates
    a separate one for the repo it is installing into, named so it cannot
    collide, so the repo ends up with pgvector registered either way.

    Detection reads every `*.exs` file directly inside your config
    directory, plus every `lib/**/*.ex` file that mentions
    `Postgrex.Types.define`. It does not evaluate config, so a `:types` key
    that only exists in a file imported from outside the config directory,
    or that is built at runtime, is invisible to it - the installer will
    generate a second types module. If that happens, delete the generated
    module and add `Pgvector.Extensions.Vector` to yours instead.

    ## Options

      * `--no-dashboard` - Skip adding the dashboard route
      * `--repo` - The repo to use (defaults to YourApp.Repo)
    """

    use Igniter.Mix.Task

    alias Igniter.Code.Function
    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Config
    # Aliased, because plain Module is Elixir's and this file uses both.
    alias Igniter.Project.Module, as: IgniterModule

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
      # Igniter's own run/1 wrapper runs "compile", not "app.config", so
      # config/runtime.exs is still unread here and a repo that configures
      # its :priv there would be invisible to migrations_path/1.
      Mix.Task.run("app.config")

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

      {igniter, unparsable_lib} = include_types_candidates(igniter)
      {existing_types, unparsable_config} = existing_types_module(igniter, app_name, repo_module)

      igniter
      |> create_migration(repo_module)
      |> setup_postgrex_types(existing_types, app_name, repo_module, types_module)
      |> maybe_warn_unparsable(unparsable_lib ++ unparsable_config)
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
      migrations_path = Arcana.MixHelpers.migrations_path(repo_module)
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

      Detection ran without them. If one of them defines or configures a
      types module, remove the one Arcana just generated (if any) and add
      Pgvector.Extensions.Vector to yours instead.
      """)
    end

    # Detects an existing Postgrex types module. The `:types` key on the repo
    # being configured is authoritative; a Postgrex.Types.define/3 call found
    # by scanning lib/ is a hint, since it may belong to a different repo.
    #
    # Returns the detection result plus any config files that could not be
    # parsed, so the caller can say detection ran with a blind spot.
    defp existing_types_module(igniter, app_name, repo_module) do
      case configured_repo_types(igniter, app_name, repo_module) do
        {nil, unparsable} -> {find_postgrex_types_define(igniter), unparsable}
        {configured, unparsable} -> {configured, unparsable}
      end
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

    # Scans every config file for `config :app, Repo, types: ...`. Igniter's
    # config helpers look at one named file and don't follow `import_config`,
    # so the whole config directory gets scanned rather than a hardcoded list
    # of the usual env files.
    defp configured_repo_types(igniter, app_name, repo_module) do
      {found, unparsable} =
        igniter
        |> config_file_names()
        |> Enum.reduce_while({nil, []}, fn file, {_found, unparsable} ->
          case configured_types_in(igniter, file, app_name, repo_module) do
            :none -> {:cont, {nil, unparsable}}
            :unparsable -> {:cont, {nil, [config_path(igniter, file) | unparsable]}}
            {:ok, module} -> {:halt, {{:config, config_path(igniter, file), module}, unparsable}}
          end
        end)

      {found, Enum.reverse(unparsable)}
    end

    defp config_file_names(igniter) do
      dir = config_dir(igniter)

      igniter
      |> project_file_paths(dir)
      |> Enum.filter(&(Path.dirname(&1) == dir and String.ends_with?(&1, ".exs")))
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()
    end

    defp project_file_paths(igniter, dir) do
      if igniter.assigns[:test_mode?] do
        Map.keys(igniter.assigns[:test_files])
      else
        Path.wildcard(Path.join(dir, "*.exs"))
      end
    end

    # Igniter addresses config files by name relative to the project's config
    # directory, which `:config_path` in mix.exs can move.
    defp config_dir(igniter) do
      igniter
      |> Igniter.Project.Application.config_path()
      |> Path.dirname()
    end

    defp config_path(igniter, file), do: Path.join(config_dir(igniter), file)

    defp configured_types_in(igniter, file, app_name, repo_module) do
      if Config.configures_key?(igniter, file, app_name, [repo_module, :types]) do
        {:ok, configured_types_module(igniter, file, app_name, repo_module)}
      else
        :none
      end
    rescue
      _ -> :unparsable
    end

    # Best effort: `configures_key?/4` above already said the key is there,
    # this only recovers the module name for the notice. The two-argument
    # `config :app, Repo: [types: ...]` shape and any non-literal value
    # degrade to :unknown rather than naming the wrong module.
    defp configured_types_module(igniter, file, app_name, repo_module) do
      with {:ok, zipper} <- config_zipper(igniter, file),
           {:ok, call} <- move_to_repo_config(zipper, app_name, repo_module),
           {:ok, opts} <- Function.move_to_nth_argument(call, 2),
           {:ok, value} <- Igniter.Code.Keyword.get_key(opts, :types),
           {:__aliases__, _, parts} when is_list(parts) <- Sourceror.Zipper.node(value),
           true <- Enum.all?(parts, &is_atom/1) do
        Module.concat(parts)
      else
        _ -> :unknown
      end
    rescue
      _ -> :unknown
    end

    defp move_to_repo_config(zipper, app_name, repo_module) do
      Function.move_to_function_call_in_current_scope(zipper, :config, 3, fn call ->
        Function.argument_equals?(call, 0, app_name) and
          Function.argument_equals?(call, 1, repo_module)
      end)
    end

    defp config_zipper(igniter, file) do
      path = config_path(igniter, file)
      igniter = Igniter.include_existing_file(igniter, path, required?: false)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} -> {:ok, source |> Rewrite.Source.get(:quoted) |> Sourceror.Zipper.zip()}
        _ -> :error
      end
    end

    defp setup_postgrex_types(igniter, nil, app_name, repo_module, types_module) do
      {igniter, chosen} =
        free_types_module(igniter, candidates(types_module, repo_module), nil, nil)

      igniter
      |> create_postgrex_types_module(chosen)
      |> configure_repo_types(app_name, repo_module, chosen)
      |> Igniter.add_notice("""

      Arcana generated #{inspect(chosen)} because it found no existing
      Postgrex types module. It looked in #{config_dir(igniter)}/*.exs and in
      lib/**/*.ex; config imported from elsewhere or built at runtime is not
      followed. If you already have one, delete the generated module and add
      Pgvector.Extensions.Vector to yours instead.
      """)
    end

    defp setup_postgrex_types(
           igniter,
           {:config, _path, _module} = existing,
           app_name,
           repo_module,
           _types_module
         ) do
      Igniter.add_notice(igniter, existing_types_notice(existing, app_name, repo_module))
    end

    # A Postgrex.Types.define/3 call found by scanning lib/ says nothing about
    # which repo it serves, and types modules are per-repo. Skipping here would
    # leave the repo Arcana is installing into with no `:types` key at all, so
    # pgvector would never be registered for it. Generate one anyway, under a
    # name that can't collide with the module that's already there.
    defp setup_postgrex_types(
           igniter,
           {:source, found, path},
           app_name,
           repo_module,
           types_module
         ) do
      {igniter, chosen} =
        free_types_module(igniter, candidates(types_module, repo_module), found, path)

      igniter
      |> create_postgrex_types_module(chosen)
      |> configure_repo_types(app_name, repo_module, chosen)
      |> Igniter.add_notice(scanned_types_notice(found, path, app_name, repo_module, chosen))
    end

    defp candidates(types_module, repo_module) do
      [
        types_module,
        Module.concat([repo_module, "PostgrexTypes"]),
        Module.concat([repo_module, "ArcanaPostgrexTypes"])
      ]
    end

    # Never reuse the name (or the file) of a module that's already there: that
    # collision is what made the installer overwrite other people's types
    # modules. Settling for an occupied name would be worse than stopping:
    # module creation skips a path that already exists, so the repo config would
    # end up pointing at somebody else's module, one with no pgvector extension
    # in it, and the install would fail at runtime instead of here.
    # Checking the conventional path isn't enough: nothing stops an app from
    # defining MyApp.PostgrexTypes in lib/my_app/db/types.ex, and generating a
    # second definition of a module that already exists somewhere else is its
    # own kind of breakage. IgniterModule.module_exists/2 searches the project
    # for the definition wherever it lives, and hands back an igniter carrying
    # the module index it built, which is why this threads one through.
    defp free_types_module(igniter, candidates, found, found_path) do
      candidates
      |> Enum.reduce_while({igniter, nil}, fn candidate, {igniter, _} ->
        {taken?, igniter} = types_module_taken?(igniter, candidate, found, found_path)

        if taken?, do: {:cont, {igniter, nil}}, else: {:halt, {igniter, candidate}}
      end)
      |> case do
        {_igniter, nil} -> raise Mix.Error, message: no_free_types_module_message(candidates)
        {igniter, candidate} -> {igniter, candidate}
      end
    end

    defp types_module_taken?(igniter, candidate, found, found_path) do
      path = types_module_path(candidate)
      {defined?, igniter} = module_defined?(igniter, candidate)

      {candidate == found or path == found_path or defined? or Igniter.exists?(igniter, path),
       igniter}
    end

    # The search parses the files it looks at, and its last resort parses every
    # .ex/.exs under lib/, test/ and config/, so a single unparsable file
    # anywhere in the project would otherwise abort the whole install with a
    # Sourceror error. An app mid-refactor still deserves a working installer.
    #
    # Degrading to the path check is not free: when the broken file IS the
    # candidate's own file, the path check still sees it and we skip the name.
    # When the broken file is elsewhere AND the candidate is defined somewhere
    # only the full scan would have found, we can still generate a second
    # definition of it. That trade buys an installer that runs at all, and the
    # compiler names the duplicate if it happens.
    defp module_defined?(igniter, candidate) do
      IgniterModule.module_exists(igniter, candidate)
    rescue
      _ -> {false, igniter}
    end

    defp no_free_types_module_message(candidates) do
      taken = Enum.map_join(candidates, "\n", &"  * #{inspect(&1)} (#{types_module_path(&1)})")

      """
      Arcana needs to generate a Postgrex types module with the pgvector
      extension in it, but every name it would use is already taken:

      #{taken}

      Rename or delete one of those, or add the extension to the types module
      you already have:

          Postgrex.Types.define(
            YourApp.PostgrexTypes,
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )

      and point your repo at it with `types: YourApp.PostgrexTypes`.
      """
    end

    defp scanned_types_notice(found, path, app_name, repo_module, chosen) do
      found_hint = if found == :unknown, do: "a types module", else: inspect(found)
      found_code = if found == :unknown, do: "TheModuleAbove", else: inspect(found)

      """
      Arcana found #{found_hint} defined by a Postgrex.Types.define/3 call in
      #{path}, but #{inspect(repo_module)} has no `:types` key pointing at it.

      Postgrex types modules are per-repo, so Arcana left that one alone and
      generated #{inspect(chosen)} for #{inspect(repo_module)} instead, with the
      pgvector extension in it. Nothing else has to happen for Arcana to work.

      If #{found_hint} was meant for #{inspect(repo_module)} all along, delete
      #{inspect(chosen)}, add the extension to it:

          Postgrex.Types.define(
            #{found_code},
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )

      and point the repo at that one instead:

          config :#{app_name}, #{inspect(repo_module)}, types: #{found_code}
      """
    end

    defp existing_types_notice({:config, path, existing}, _app_name, repo_module) do
      named = if existing == :unknown, do: "", else: ": #{inspect(existing)}"
      module_code = if existing == :unknown, do: "YourApp.PostgrexTypes", else: inspect(existing)

      """
      #{inspect(repo_module)} already has a `:types` module configured in
      #{path}#{named}, so Arcana skipped generating one.

      Make sure that module includes the pgvector extension:

          Postgrex.Types.define(
            #{module_code},
            [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
            []
          )
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

      Igniter.create_new_file(igniter, types_module_path(types_module), types_content,
        on_exists: :skip
      )
    end

    defp types_module_path(types_module) do
      types_module
      |> Module.split()
      |> Enum.map_join("/", &Macro.underscore/1)
      |> then(&"lib/#{&1}.ex")
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

      # Load the host app's config so the repo's `:priv`, if it has one, is
      # visible to Arcana.MixHelpers.migrations_path/1.
      Mix.Task.run("app.config")

      repo = opts[:repo] || infer_repo()

      migrations_path = Arcana.MixHelpers.migrations_path(repo)
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
