defmodule Arcana.Evaluation.Generator do
  @moduledoc """
  Generates synthetic test cases from existing chunks.

  Samples chunks and uses an LLM to generate questions that
  should retrieve those chunks.
  """

  import Ecto.Query

  alias Arcana.{Chunk, LLM}
  alias Arcana.Evaluation.TestCase

  @default_prompt """
  Given this text chunk from a document, generate a natural question that can ONLY be answered using information in this chunk.

  Requirements:
  - The question should be specific, not generic
  - Someone searching for an answer would use similar words
  - Return ONLY the question, nothing else

  Text chunk:
  {chunk_text}
  """

  @doc """
  Generates test cases from a sample of chunks.

  ## Options

    * `:repo` - Ecto repo (required)
    * `:llm` - LLM implementing Arcana.LLM protocol (required)
    * `:sample_size` - Number of chunks to sample (default: 50)
    * `:source_id` - Limit to chunks from specific source
    * `:collection` - Limit to chunks from specific collection
    * `:prompt` - Custom prompt template (must include {chunk_text})

  """
  def generate(opts) do
    repo = Keyword.fetch!(opts, :repo)
    llm = Keyword.fetch!(opts, :llm)
    sample_size = Keyword.get(opts, :sample_size, 50)
    source_id = Keyword.get(opts, :source_id)
    collection = Keyword.get(opts, :collection)
    prompt_template = Keyword.get(opts, :prompt, @default_prompt)

    chunks = sample_chunks(repo, sample_size, source_id, collection)

    test_cases =
      chunks
      |> Enum.map(fn chunk ->
        case generate_question(llm, chunk, prompt_template) do
          {:ok, question} ->
            create_test_case(repo, question, chunk)

          {:error, _} ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, test_cases}
  end

  @doc """
  Returns the default prompt template.
  """
  def default_prompt, do: @default_prompt

  defp sample_chunks(repo, sample_size, source_id, collection) do
    query =
      from(c in Chunk,
        join: d in assoc(c, :document),
        order_by: fragment("RANDOM()"),
        limit: ^sample_size
      )

    query =
      if source_id do
        from([c, d] in query, where: d.source_id == ^source_id)
      else
        query
      end

    query =
      if collection do
        from([c, d] in query,
          join: col in assoc(d, :collection),
          where: col.name == ^collection
        )
      else
        query
      end

    repo.all(query)
  end

  defp generate_question(llm, chunk, prompt_template) do
    prompt = String.replace(prompt_template, "{chunk_text}", chunk.text)
    LLM.complete(llm, prompt, [])
  end

  defp create_test_case(repo, question, source_chunk) do
    test_case =
      %TestCase{}
      |> TestCase.changeset(%{
        question: String.trim(question),
        source: :synthetic,
        source_chunk_id: source_chunk.id
      })
      |> repo.insert!()

    # Link the source chunk as a relevant chunk (convert UUIDs to binary for insert_all)
    repo.insert_all("arcana_evaluation_test_case_chunks", [
      %{
        test_case_id: Ecto.UUID.dump!(test_case.id),
        chunk_id: Ecto.UUID.dump!(source_chunk.id)
      }
    ])

    # Return with preloaded relevant_chunks
    repo.preload(test_case, :relevant_chunks)
  end
end
