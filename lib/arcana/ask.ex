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
    * `:source_id` - Filter context to a specific source. Chunks, matched
      entities, and relationships are scoped to it; community summaries
      are collection-level artifacts and may describe entities beyond the
      source. Use collections (see `:strict_collections`) for isolation.
    * `:threshold` - Minimum similarity score for context (default: 0.0)
    * `:mode` - Search mode: `:vector` (default), `:keyword`, or `:hybrid`.
      `:semantic` and `:fulltext` are deprecated aliases and log a warning.
    * `:collection` - Filter to a specific collection
    * `:collections` - Filter to multiple collections
    * `:prompt` - Custom prompt function. Supports arity 2 `(question, context)` or
      arity 3 `(question, context, graph_context)`
    * `:reranker` - Reranker module/function (passed through to search)
    * `:rewriter` - Query rewriter (passed through to search)
    * `:graph` - Enable/disable GraphRAG (default: global config)
    * `:graph_depth` - When GraphRAG is enabled, how many relationship hops
      to expand matched entities (default: 0). Affects both retrieval (chunks
      mentioning neighbor entities are pulled in, down-weighted per hop) and
      the prompt's relationship context, which then includes edges from
      matched entities to their expanded neighbors. The global default is
      `config :arcana, graph: [query_depth: n]`.

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
    prompt_fn = Keyword.get(opts, :prompt, &default_ask_prompt/3)

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
    alias Arcana.Graph.{Community, GraphStore}

    graph_config = Arcana.Graph.config()
    entity_limit = graph_config[:context_entity_limit] || 10
    rel_limit = graph_config[:context_relationship_limit] || 20
    summary_levels = Arcana.Graph.summary_levels(graph_config)
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

    # :source_id scopes the graph context too, not just the chunks:
    # matched entities (and, through them, relationships and which
    # communities are considered) are limited to the source. Community
    # SUMMARY TEXT is not: a community is a collection-level cluster, so
    # its summary can describe entities from other sources in the same
    # collection. Collections, not sources, are the isolation boundary.
    source_id = Keyword.get(opts, :source_id)
    matched_entities = scope_entities_by_source(matched_entities, source_id, repo)

    if matched_entities == [] do
      %{}
    else
      entity_ids = Enum.map(matched_entities, & &1.id)
      graph_depth = Arcana.Graph.query_depth(opts)

      expanded_ids =
        entity_ids
        |> Arcana.Graph.expand_entity_ids(graph_depth, collection_ids, repo: repo)
        |> Map.values()
        |> List.flatten()
        |> entity_ids_in_source(source_id, repo)

      relationships = fetch_relationships(expanded_ids, entity_ids, graph_depth, rel_limit, repo)

      level_filter =
        case summary_levels do
          :all -> dynamic([c], not is_nil(c.level))
          levels -> dynamic([c], c.level in ^levels)
        end

      matched_binary = entity_ids_to_binary(entity_ids)

      # Without an ORDER BY, Postgres returns whichever overlapping
      # communities it likes and the LIMIT cuts arbitrarily, so the single
      # most relevant community can lose its slot to five that share one
      # peripheral entity each.
      #
      # Overlap size descending puts the most on-topic first. Community size
      # ascending breaks ties away from hub communities, which overlap
      # almost any entity set and summarise too broadly to be useful.
      community_summaries =
        repo.all(
          from(c in Community,
            where:
              fragment("? && ?", c.entity_ids, ^matched_binary) and
                not is_nil(c.summary) and c.summary != "",
            where: ^level_filter,
            order_by: [
              desc:
                fragment(
                  "cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::uuid[])))",
                  c.entity_ids,
                  ^matched_binary
                ),
              asc: fragment("cardinality(?)", c.entity_ids),
              asc: c.id
            ],
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

  # With no traversal the context keeps its original shape: only edges whose
  # source AND target both matched the query. With graph_depth > 0 the edge
  # closure runs over the expanded entity set, ordered so edges touching a
  # directly matched entity win the limit over neighbor-to-neighbor edges.
  defp fetch_relationships(expanded_ids, _matched_ids, 0, rel_limit, repo) do
    import Ecto.Query
    alias Arcana.Graph.{Entity, Relationship}

    repo.all(
      from(r in Relationship,
        join: src in Entity,
        on: r.source_id == src.id,
        join: tgt in Entity,
        on: r.target_id == tgt.id,
        where: r.source_id in ^expanded_ids and r.target_id in ^expanded_ids,
        select: %{source: src.name, target: tgt.name, type: r.type},
        limit: ^rel_limit
      )
    )
  end

  defp fetch_relationships(expanded_ids, matched_ids, _depth, rel_limit, repo) do
    import Ecto.Query
    alias Arcana.Graph.{Entity, Relationship}

    repo.all(
      from(r in Relationship,
        join: src in Entity,
        on: r.source_id == src.id,
        join: tgt in Entity,
        on: r.target_id == tgt.id,
        where: r.source_id in ^expanded_ids and r.target_id in ^expanded_ids,
        order_by: [desc: r.source_id in ^matched_ids or r.target_id in ^matched_ids],
        select: %{source: src.name, target: tgt.name, type: r.type},
        limit: ^rel_limit
      )
    )
  end

  defp scope_entities_by_source(entities, nil, _repo), do: entities
  defp scope_entities_by_source([], _source_id, _repo), do: []

  defp scope_entities_by_source(entities, source_id, repo) do
    in_source =
      entities
      |> Enum.map(& &1.id)
      |> entity_ids_in_source(source_id, repo)
      |> MapSet.new()

    Enum.filter(entities, &MapSet.member?(in_source, &1.id))
  end

  # An entity belongs to a source when at least one of its mentions sits
  # on a chunk of a document with that source_id.
  defp entity_ids_in_source(ids, nil, _repo), do: ids
  defp entity_ids_in_source([], _source_id, _repo), do: []

  defp entity_ids_in_source(ids, source_id, repo) do
    import Ecto.Query
    alias Arcana.{Chunk, Document}
    alias Arcana.Graph.EntityMention

    repo.all(
      from(m in EntityMention,
        join: c in Chunk,
        on: c.id == m.chunk_id,
        join: d in Document,
        on: d.id == c.document_id,
        where: m.entity_id in ^ids and d.source_id == ^source_id,
        select: m.entity_id,
        distinct: true
      )
    )
  end

  defp entity_ids_to_binary(entity_ids) do
    Enum.map(entity_ids, fn id ->
      {:ok, bin} = Ecto.UUID.dump(id)
      bin
    end)
  end

  # `nil` means unscoped; `[]` means the named collections resolved to
  # nothing and downstream graph queries must match nothing. Strict
  # validation already happened in Arcana.Search.search/2.
  defp resolve_collection_ids(opts, repo) do
    {:ok, ids} =
      Arcana.Collection.names_from_opts(opts)
      |> Arcana.Collection.resolve_ids(repo)

    ids
  end
end
