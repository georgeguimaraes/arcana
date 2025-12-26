defmodule Mix.Tasks.Arcana.Eval.Generate do
  @shortdoc "Generate synthetic test cases for retrieval evaluation"

  @moduledoc """
  Generates synthetic test cases from existing chunks.

  ## Usage

      mix arcana.eval.generate --sample-size 50
      mix arcana.eval.generate --source-id my-docs --sample-size 100

  ## Options

    * `--sample-size` - Number of chunks to sample (default: 50)
    * `--source-id` - Limit to chunks from specific source

  ## Configuration

  Requires `:repo` and `:llm` to be configured in your application:

      config :arcana,
        repo: MyApp.Repo,
        llm: my_llm_function

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [sample_size: :integer, source_id: :string]
      )

    sample_size = Keyword.get(opts, :sample_size, 50)
    source_id = Keyword.get(opts, :source_id)

    repo = Application.get_env(:arcana, :repo) || raise "Missing :arcana, :repo config"
    llm = Application.get_env(:arcana, :llm) || raise "Missing :arcana, :llm config"

    IO.puts("Generating test cases from #{sample_size} chunks...")

    generation_opts = [
      repo: repo,
      llm: llm,
      sample_size: sample_size,
      source_id: source_id
    ]

    case Arcana.Evaluation.generate_test_cases(generation_opts) do
      {:ok, test_cases} ->
        IO.puts("Generated #{length(test_cases)} test cases")

      {:error, reason} ->
        IO.puts("Failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
