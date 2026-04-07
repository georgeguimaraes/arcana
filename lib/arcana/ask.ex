defmodule Arcana.Ask do
  @moduledoc """
  RAG (Retrieval Augmented Generation) question answering.

  This module handles the core ask workflow:
  1. Search for relevant context chunks
  2. Build a prompt with the context
  3. Call the LLM for an answer

  ## Usage

      {:ok, answer, context} = Arcana.ask("What is X?",
        repo: MyApp.Repo,
        llm: "openai:gpt-4o-mini"
      )

  """

  alias Arcana.LLM

  @doc """
  Asks a question using retrieved context from the knowledge base.

  Performs a search to find relevant chunks, then passes them along with
  the question to an LLM for answer generation.

  ## Options

    * `:repo` - The Ecto repo to use (required)
    * `:llm` - Any type implementing the `Arcana.LLM` protocol (required)
    * `:limit` - Maximum number of context chunks to retrieve (default: 5)
    * `:source_id` - Filter context to a specific source
    * `:threshold` - Minimum similarity score for context (default: 0.0)
    * `:mode` - Search mode: `:semantic` (default), `:fulltext`, or `:hybrid`
    * `:collection` - Filter to a specific collection
    * `:collections` - Filter to multiple collections
    * `:prompt` - Custom prompt function. Supports arity 2 `(question, context)` or
      arity 3 `(question, context, graph_context)`
    * `:reranker` - Reranker module/function (passed through to search)
    * `:rewriter` - Query rewriter (passed through to search)
    * `:graph` - Enable/disable GraphRAG (default: global config)

  Defaults for `:limit` can be set globally:

      config :arcana, ask: [limit: 5]

  ## Examples

      # Basic usage
      {:ok, answer, context} = Arcana.ask("What is Elixir?",
        repo: MyApp.Repo,
        llm: "openai:gpt-4o-mini"
      )

      # With custom prompt
      {:ok, answer, _} = Arcana.ask("Summarize the docs",
        repo: MyApp.Repo,
        llm: my_llm,
        prompt: fn question, context ->
          "Be concise. Question: \#{question}"
        end
      )

  """
  def ask(question, opts) when is_binary(question) do
    opts = Arcana.Config.merge_app_opts(opts, :ask)
    repo = Arcana.Config.get(opts, :repo)
    llm = Arcana.Config.get(opts, :llm)

    if is_nil(llm), do: {:error, :no_llm_configured}, else: do_ask(question, opts, repo, llm)
  end

  defp do_ask(question, opts, repo, llm) do
    start_metadata = %{question: question, repo: repo}

    :telemetry.span([:arcana, :ask], start_metadata, fn ->
      # Forward everything except ask-specific keys so backend tuning flows through
      search_opts =
        opts
        |> Keyword.drop([:llm, :prompt])
        |> Keyword.put_new(:limit, 5)

      case Arcana.Search.search(question, search_opts) do
        {:ok, context} -> ask_with_context(question, context, opts, llm)
        {:error, reason} -> {{:error, {:search_failed, reason}}, %{error: reason}}
      end
    end)
  end

  defp ask_with_context(question, context, opts, llm) do
    graph_context = maybe_fetch_graph_context(question, opts)
    prompt_fn = Keyword.get(opts, :prompt, &default_ask_prompt/2)

    llm_opts = [
      system_prompt:
        case Function.info(prompt_fn, :arity) do
          {:arity, 3} -> prompt_fn.(question, context, graph_context)
          {:arity, _} -> prompt_fn.(question, context)
        end
    ]

    result =
      case LLM.complete(llm, question, context, llm_opts) do
        {:ok, answer} -> {:ok, answer, context}
        {:error, reason} -> {:error, reason}
      end

    stop_metadata =
      case result do
        {:ok, answer, _} -> %{answer: answer, context_count: length(context)}
        {:error, _} -> %{context_count: length(context)}
      end

    {result, stop_metadata}
  end

  defp default_ask_prompt(question, context),
    do: default_ask_prompt(question, context, %{})

  defp default_ask_prompt(_question, context, graph_context) when is_map(graph_context) do
    context_text =
      Enum.map_join(context, "\n\n---\n\n", fn
        %{text: text} -> text
        text when is_binary(text) -> text
        other -> inspect(other)
      end)

    graph_sections = format_graph_sections(graph_context)

    if context_text != "" do
      """
      Answer the user's question based on the following context.
      If the answer is not in the context, say you don't know.
      #{graph_sections}
      Source passages:
      #{context_text}
      """
    else
      "You are a helpful assistant."
    end
  end

  # Backward compat: list of community summaries
  defp default_ask_prompt(question, context, community_summaries)
       when is_list(community_summaries) do
    default_ask_prompt(question, context, %{community_summaries: community_summaries})
  end

  defp format_graph_sections(%{} = ctx) do
    sections = []

    sections =
      case Map.get(ctx, :entities, []) do
        [] ->
          sections

        entities ->
          entity_text =
            Enum.map_join(entities, "\n", fn e ->
              desc = if e[:description], do: ": #{e.description}", else: ""
              "- #{e.name} (#{e.type})#{desc}"
            end)

          sections ++ ["\nRelevant entities:\n#{entity_text}"]
      end

    sections =
      case Map.get(ctx, :relationships, []) do
        [] ->
          sections

        rels ->
          rel_text =
            Enum.map_join(rels, "\n", fn r ->
              "- #{r.source} --[#{r.type}]--> #{r.target}"
            end)

          sections ++ ["\nRelationships:\n#{rel_text}"]
      end

    sections =
      case Map.get(ctx, :community_summaries, []) do
        [] ->
          sections

        summaries ->
          text = Enum.map_join(summaries, "\n\n", & &1)
          sections ++ ["\nBackground knowledge:\n#{text}"]
      end

    Enum.join(sections, "\n")
  end

  defp maybe_fetch_graph_context(question, opts) do
    repo = Arcana.Config.get(opts, :repo)

    if Arcana.Config.graph_enabled?(opts) and repo do
      fetch_graph_context(question, repo, opts)
    else
      %{}
    end
  end

  defp fetch_graph_context(question, repo, opts) do
    import Ecto.Query
    alias Arcana.Graph.{Community, Entity, GraphStore, Relationship}

    graph_config = Arcana.Graph.config()
    entity_limit = graph_config[:context_entity_limit] || 10
    rel_limit = graph_config[:context_relationship_limit] || 20
    summary_level = graph_config[:community_summary_level] || 0
    summary_limit = graph_config[:community_summary_limit] || 5
    threshold = graph_config[:entity_embedding_threshold] || 0.3

    collection_ids = resolve_collection_ids(opts, repo)
    embedder = Arcana.Config.embedder()

    matched_entities =
      case Arcana.Embedder.embed(embedder, question, intent: :query) do
        {:ok, query_embedding} ->
          GraphStore.search_by_embedding(query_embedding, collection_ids,
            repo: repo,
            limit: entity_limit,
            threshold: threshold
          )

        _ ->
          []
      end

    if matched_entities == [] do
      %{}
    else
      entity_ids = Enum.map(matched_entities, & &1.id)

      relationships =
        repo.all(
          from(r in Relationship,
            join: src in Entity,
            on: r.source_id == src.id,
            join: tgt in Entity,
            on: r.target_id == tgt.id,
            where: r.source_id in ^entity_ids and r.target_id in ^entity_ids,
            select: %{source: src.name, target: tgt.name, type: r.type},
            limit: ^rel_limit
          )
        )

      community_summaries =
        repo.all(
          from(c in Community,
            where:
              fragment("? && ?", c.entity_ids, ^entity_ids_to_binary(entity_ids)) and
                not is_nil(c.summary) and c.summary != "" and
                c.level == ^summary_level,
            select: c.summary,
            limit: ^summary_limit
          )
        )

      %{
        entities: matched_entities,
        relationships: relationships,
        community_summaries: community_summaries
      }
    end
  end

  defp entity_ids_to_binary(entity_ids) do
    Enum.map(entity_ids, fn id ->
      {:ok, bin} = Ecto.UUID.dump(id)
      bin
    end)
  end

  defp resolve_collection_ids(opts, repo) do
    case Arcana.Collection.names_from_opts(opts) |> Arcana.Collection.resolve_ids(repo) do
      nil -> nil
      [] -> nil
      ids -> ids
    end
  end
end
