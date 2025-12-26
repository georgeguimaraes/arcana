defmodule Mix.Tasks.Arcana.Eval.Run do
  @shortdoc "Run retrieval evaluation against test cases"

  @moduledoc """
  Runs evaluation and prints metrics.

  ## Usage

      mix arcana.eval.run
      mix arcana.eval.run --mode hybrid
      mix arcana.eval.run --generate --sample-size 50
      mix arcana.eval.run --format json > results.json

  ## Options

    * `--mode` - Search mode: semantic, fulltext, hybrid (default: semantic)
    * `--source-id` - Limit to specific source
    * `--generate` - Generate test cases first if none exist
    * `--sample-size` - Sample size for generation (default: 50)
    * `--format` - Output format: table, json (default: table)
    * `--fail-under` - Exit 1 if recall@5 below threshold (for CI)

  ## Configuration

  Requires `:repo` to be configured in your application:

      config :arcana, repo: MyApp.Repo

  If using `--generate`, also requires `:llm` to be configured.

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          mode: :string,
          source_id: :string,
          generate: :boolean,
          sample_size: :integer,
          format: :string,
          fail_under: :float
        ]
      )

    repo = Application.get_env(:arcana, :repo) || raise "Missing :arcana, :repo config"

    mode =
      case Keyword.get(opts, :mode, "semantic") do
        "semantic" -> :semantic
        "fulltext" -> :fulltext
        "hybrid" -> :hybrid
        other -> raise "Invalid mode: #{other}"
      end

    maybe_generate(repo, opts)

    IO.puts("Running evaluation...")

    run_opts = [
      repo: repo,
      mode: mode,
      source_id: Keyword.get(opts, :source_id)
    ]

    case Arcana.Evaluation.run(run_opts) do
      {:ok, run} ->
        print_results(run, Keyword.get(opts, :format, "table"))
        check_threshold(run, Keyword.get(opts, :fail_under))

      {:error, :no_test_cases} ->
        IO.puts("No test cases found. Run with --generate first.")
        exit({:shutdown, 1})
    end
  end

  defp maybe_generate(repo, opts) do
    if Keyword.get(opts, :generate) do
      count = Arcana.Evaluation.count_test_cases(repo: repo)

      if count == 0 do
        llm = Application.get_env(:arcana, :llm) || raise "Missing :arcana, :llm config"
        sample_size = Keyword.get(opts, :sample_size, 50)

        IO.puts("No test cases found. Generating #{sample_size}...")

        {:ok, test_cases} =
          Arcana.Evaluation.generate_test_cases(
            repo: repo,
            llm: llm,
            sample_size: sample_size,
            source_id: Keyword.get(opts, :source_id)
          )

        IO.puts("Generated #{length(test_cases)} test cases")
      end
    end
  end

  defp print_results(run, "table") do
    m = run.metrics

    IO.puts("")
    IO.puts(String.duplicate("=", 42))
    IO.puts("         Evaluation Results")
    IO.puts(String.duplicate("=", 42))
    IO.puts("  Recall@1:     #{format_pct(m.recall_at_1)}")
    IO.puts("  Recall@3:     #{format_pct(m.recall_at_3)}")
    IO.puts("  Recall@5:     #{format_pct(m.recall_at_5)}")
    IO.puts("  Recall@10:    #{format_pct(m.recall_at_10)}")
    IO.puts(String.duplicate("-", 42))
    IO.puts("  Precision@1:  #{format_pct(m.precision_at_1)}")
    IO.puts("  Precision@5:  #{format_pct(m.precision_at_5)}")
    IO.puts(String.duplicate("-", 42))
    IO.puts("  MRR:          #{format_pct(m.mrr)}")
    IO.puts("  Hit Rate@5:   #{format_pct(m.hit_rate_at_5)}")
    IO.puts(String.duplicate("-", 42))
    IO.puts("  Test Cases:   #{m.test_case_count}")
    IO.puts(String.duplicate("=", 42))
  end

  defp print_results(run, "json") do
    run
    |> Map.take([:metrics, :test_case_count, :config, :inserted_at])
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp format_pct(value) when is_float(value) do
    "#{Float.round(value * 100, 1)}%"
    |> String.pad_leading(8)
  end

  defp check_threshold(_run, nil), do: :ok

  defp check_threshold(run, threshold) do
    recall = run.metrics.recall_at_5

    if recall < threshold do
      IO.puts(
        "\nRecall@5 (#{Float.round(recall * 100, 1)}%) below threshold (#{threshold * 100}%)"
      )

      exit({:shutdown, 1})
    else
      IO.puts("\nRecall@5 meets threshold (#{threshold * 100}%)")
    end
  end
end
