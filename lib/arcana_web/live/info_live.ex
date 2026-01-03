defmodule ArcanaWeb.InfoLive do
  @moduledoc """
  LiveView for displaying Arcana configuration info.
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(config_info: get_config_info())
     |> assign(stats: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
  end

  defp get_config_info do
    %{
      repo: Application.get_env(:arcana, :repo),
      llm: format_llm_config(Application.get_env(:arcana, :llm)),
      embedding: format_embedding_config(Application.get_env(:arcana, :embedder, :local)),
      chunker: format_chunker_config(Application.get_env(:arcana, :chunker, :default)),
      reranker: format_reranker_config(Application.get_env(:arcana, :reranker)),
      vector_store: format_vector_store_config(),
      graph: format_graph_config(),
      raw: %{
        embedder: Arcana.Config.redact(Application.get_env(:arcana, :embedder, :local)),
        llm: Arcana.Config.redact(Application.get_env(:arcana, :llm)),
        reranker: Arcana.Config.redact(Application.get_env(:arcana, :reranker)),
        chunker: Arcana.Config.redact(Application.get_env(:arcana, :chunker, :default)),
        graph: Arcana.Config.redact(Application.get_env(:arcana, :graph, [])),
        vector_store: Application.get_env(:arcana, :vector_store, :pgvector)
      }
    }
  end

  defp format_llm_config(nil), do: %{configured: false}

  defp format_llm_config(llm) when is_function(llm) do
    %{configured: true, type: "Function"}
  end

  defp format_llm_config(llm) do
    case llm do
      %{__struct__: module} = struct ->
        %{
          configured: true,
          type: module |> Module.split() |> List.last(),
          model: Map.get(struct, :model, "unknown")
        }

      {model, _opts} when is_binary(model) ->
        %{configured: true, type: "Req.LLM", model: model}

      {model, _opts} when is_atom(model) ->
        %{configured: true, type: "Req.LLM", model: Atom.to_string(model)}

      model when is_binary(model) ->
        %{configured: true, type: "Req.LLM", model: model}

      model when is_atom(model) ->
        %{configured: true, type: "Req.LLM", model: Atom.to_string(model)}

      _ ->
        %{configured: true, type: "Custom"}
    end
  end

  defp format_embedding_config(:local), do: %{type: :local, model: "BAAI/bge-small-en-v1.5"}
  defp format_embedding_config(:openai), do: %{type: :openai, model: "text-embedding-3-small"}

  defp format_embedding_config({:local, opts}) do
    %{type: :local, model: Keyword.get(opts, :model, "BAAI/bge-small-en-v1.5")}
  end

  defp format_embedding_config({:openai, opts}) do
    %{type: :openai, model: Keyword.get(opts, :model, "text-embedding-3-small")}
  end

  defp format_embedding_config({:custom, _fun}), do: %{type: :custom}
  defp format_embedding_config({:custom, _fun, _opts}), do: %{type: :custom}

  defp format_embedding_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{type: :custom_module, module: module, opts: Arcana.Config.do_redact(opts)}
  end

  defp format_embedding_config(module) when is_atom(module) do
    %{type: :custom_module, module: module}
  end

  defp format_embedding_config(other), do: %{type: :unknown, raw: inspect(other)}

  defp format_reranker_config(nil), do: %{module: Arcana.Reranker.LLM, configured: false}

  defp format_reranker_config(module) when is_atom(module),
    do: %{module: module, configured: true}

  defp format_reranker_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{module: module, opts: Arcana.Config.do_redact(opts), configured: true}
  end

  defp format_reranker_config(fun) when is_function(fun) do
    %{type: :function, configured: true}
  end

  defp format_reranker_config(other),
    do: %{type: :unknown, raw: Arcana.Config.do_redact(other), configured: true}

  defp format_chunker_config(:default), do: %{type: :default, chunk_size: 512, chunk_overlap: 100}

  defp format_chunker_config({:default, opts}) do
    %{
      type: :default,
      chunk_size: Keyword.get(opts, :chunk_size, 512),
      chunk_overlap: Keyword.get(opts, :chunk_overlap, 100)
    }
  end

  defp format_chunker_config(fun) when is_function(fun), do: %{type: :function}

  defp format_chunker_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{type: :custom, module: module, opts: Arcana.Config.do_redact(opts)}
  end

  defp format_chunker_config(module) when is_atom(module), do: %{type: :custom, module: module}
  defp format_chunker_config(_other), do: %{type: :unknown}

  defp format_vector_store_config do
    store = Application.get_env(:arcana, :vector_store, :pgvector)

    case store do
      :pgvector -> %{type: :pgvector, description: "PostgreSQL with pgvector extension"}
      :memory -> %{type: :memory, description: "In-memory vector store"}
      module when is_atom(module) -> %{type: :custom, module: module}
      _ -> %{type: :unknown}
    end
  end

  defp format_graph_config do
    config = Arcana.Graph.config()
    graph_opts = Application.get_env(:arcana, :graph, [])

    extractor =
      cond do
        config[:extractor] -> format_extractor(config[:extractor])
        graph_opts[:extractor] -> format_extractor(graph_opts[:extractor])
        true -> nil
      end

    entity_extractor =
      cond do
        config[:entity_extractor] -> format_extractor(config[:entity_extractor])
        graph_opts[:entity_extractor] -> format_extractor(graph_opts[:entity_extractor])
        true -> %{type: :ner, description: "Built-in NER (default)"}
      end

    relationship_extractor =
      cond do
        config[:relationship_extractor] ->
          format_extractor(config[:relationship_extractor])

        graph_opts[:relationship_extractor] ->
          format_extractor(graph_opts[:relationship_extractor])

        true ->
          nil
      end

    %{
      enabled: config.enabled,
      community_levels: config.community_levels,
      resolution: config.resolution,
      store: Application.get_env(:arcana, :graph_store, :ecto),
      extractor: extractor,
      entity_extractor: entity_extractor,
      relationship_extractor: relationship_extractor
    }
  end

  defp format_extractor(nil), do: nil
  defp format_extractor(:ner), do: %{type: :ner, description: "Built-in NER"}
  defp format_extractor(:llm), do: %{type: :llm, description: "LLM-based extraction"}

  defp format_extractor({module, opts}) when is_atom(module) and is_list(opts) do
    module_name = module |> Module.split() |> List.last()
    %{type: :custom, module: module_name, opts: Arcana.Config.do_redact(opts)}
  end

  defp format_extractor(module) when is_atom(module) do
    module_name = module |> Module.split() |> List.last()
    %{type: :module, module: module_name}
  end

  defp format_extractor(_other), do: %{type: :unknown}

  defp raw_config_section(assigns) do
    config_text = """
    config :arcana,
      repo: #{inspect(assigns.config_info.repo)},
      embedder: #{inspect(assigns.config_info.raw.embedder)},
      llm: #{inspect(assigns.config_info.raw.llm)},
      chunker: #{inspect(assigns.config_info.raw.chunker)},
      reranker: #{if assigns.config_info.raw.reranker, do: inspect(assigns.config_info.raw.reranker), else: "nil # defaults to Arcana.Reranker.LLM"},
      vector_store: #{inspect(assigns.config_info.raw.vector_store)},
      graph: #{inspect(assigns.config_info.raw.graph)}
    """

    assigns = assign(assigns, :config_text, config_text)

    ~H"""
    <div class="arcana-info-section arcana-info-full">
      <h3>Raw Configuration</h3>
      <pre class="arcana-doc-content" style="font-size: 0.75rem; line-height: 1.5; overflow-x: auto;"><%= @config_text %></pre>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:info}>
      <div class="arcana-info">
        <h2>Info</h2>
        <p class="arcana-tab-description">
          View current Arcana configuration including embedding, LLM, and chunking settings.
        </p>

        <div class="arcana-info-grid">
          <div class="arcana-info-section">
            <h3>Embedding</h3>
            <div class="arcana-doc-info">
              <div class="arcana-doc-field">
                <label>Type</label>
                <span><%= @config_info.embedding.type %></span>
              </div>
              <%= if @config_info.embedding[:model] do %>
                <div class="arcana-doc-field">
                  <label>Model</label>
                  <span><%= @config_info.embedding.model %></span>
                </div>
              <% end %>
              <%= if @config_info.embedding[:module] do %>
                <div class="arcana-doc-field">
                  <label>Module</label>
                  <code><%= inspect(@config_info.embedding.module) %></code>
                </div>
              <% end %>
            </div>
          </div>

          <div class="arcana-info-section">
            <h3>LLM</h3>
            <div class="arcana-doc-info">
              <%= if @config_info.llm.configured do %>
                <div class="arcana-doc-field">
                  <label>Type</label>
                  <span><%= @config_info.llm.type %></span>
                </div>
                <%= if @config_info.llm[:model] do %>
                  <div class="arcana-doc-field">
                    <label>Model</label>
                    <span><%= @config_info.llm.model %></span>
                  </div>
                <% end %>
              <% else %>
                <div class="arcana-doc-field">
                  <label>Status</label>
                  <span class="arcana-not-configured">Not configured</span>
                </div>
              <% end %>
            </div>
          </div>

          <div class="arcana-info-section">
            <h3>Chunker</h3>
            <div class="arcana-doc-info">
              <div class="arcana-doc-field">
                <label>Type</label>
                <span><%= @config_info.chunker.type %></span>
              </div>
              <%= if @config_info.chunker[:chunk_size] do %>
                <div class="arcana-doc-field">
                  <label>Chunk Size</label>
                  <span><%= @config_info.chunker.chunk_size %> tokens</span>
                </div>
              <% end %>
              <%= if @config_info.chunker[:chunk_overlap] do %>
                <div class="arcana-doc-field">
                  <label>Overlap</label>
                  <span><%= @config_info.chunker.chunk_overlap %> tokens</span>
                </div>
              <% end %>
              <%= if @config_info.chunker[:module] do %>
                <div class="arcana-doc-field">
                  <label>Module</label>
                  <code><%= inspect(@config_info.chunker.module) %></code>
                </div>
              <% end %>
            </div>
          </div>

          <div class="arcana-info-section">
            <h3>Reranker</h3>
            <div class="arcana-doc-info">
              <div class="arcana-doc-field">
                <label>Module</label>
                <code><%= inspect(@config_info.reranker[:module] || @config_info.reranker[:type]) %></code>
              </div>
              <%= if @config_info.reranker[:opts] do %>
                <div class="arcana-doc-field">
                  <label>Options</label>
                  <span><%= inspect(@config_info.reranker.opts) %></span>
                </div>
              <% end %>
              <div class="arcana-doc-field">
                <label>Status</label>
                <span><%= if @config_info.reranker.configured, do: "Configured", else: "Default" %></span>
              </div>
            </div>
          </div>

          <div class="arcana-info-section">
            <h3>Vector Store</h3>
            <div class="arcana-doc-info">
              <div class="arcana-doc-field">
                <label>Type</label>
                <span><%= @config_info.vector_store.type %></span>
              </div>
              <%= if @config_info.vector_store[:description] do %>
                <div class="arcana-doc-field">
                  <label>Description</label>
                  <span><%= @config_info.vector_store.description %></span>
                </div>
              <% end %>
              <%= if @config_info.vector_store[:module] do %>
                <div class="arcana-doc-field">
                  <label>Module</label>
                  <code><%= inspect(@config_info.vector_store.module) %></code>
                </div>
              <% end %>
            </div>
          </div>

          <div class="arcana-info-section">
            <h3>GraphRAG</h3>
            <div class="arcana-doc-info">
              <div class="arcana-doc-field">
                <label>Status</label>
                <span class={"arcana-status-badge #{if @config_info.graph.enabled, do: "enabled", else: "disabled"}"}>
                  <%= if @config_info.graph.enabled, do: "Enabled", else: "Disabled" %>
                </span>
              </div>
              <%= if @config_info.graph.extractor do %>
                <div class="arcana-doc-field">
                  <label>Extractor</label>
                  <span>
                    <%= @config_info.graph.extractor[:module] || @config_info.graph.extractor[:description] || @config_info.graph.extractor[:type] %>
                    <span style="color: #6b7280; font-size: 0.75rem;">(combined)</span>
                  </span>
                </div>
              <% else %>
                <%= if @config_info.graph.entity_extractor do %>
                  <div class="arcana-doc-field">
                    <label>Entity Extractor</label>
                    <span><%= @config_info.graph.entity_extractor[:module] || @config_info.graph.entity_extractor[:description] || @config_info.graph.entity_extractor[:type] %></span>
                  </div>
                <% end %>
                <%= if @config_info.graph.relationship_extractor do %>
                  <div class="arcana-doc-field">
                    <label>Relationship Extractor</label>
                    <span><%= @config_info.graph.relationship_extractor[:module] || @config_info.graph.relationship_extractor[:description] || @config_info.graph.relationship_extractor[:type] %></span>
                  </div>
                <% end %>
              <% end %>
              <div class="arcana-doc-field">
                <label>Community Levels</label>
                <span><%= @config_info.graph.community_levels %></span>
              </div>
              <div class="arcana-doc-field">
                <label>Resolution</label>
                <span><%= @config_info.graph.resolution %></span>
              </div>
              <div class="arcana-doc-field">
                <label>Store</label>
                <span><%= @config_info.graph.store %></span>
              </div>
            </div>
          </div>
        </div>

        <div class="arcana-info-section arcana-info-full">
          <h3>Repository</h3>
          <div class="arcana-doc-info">
            <div class="arcana-doc-field">
              <label>Module</label>
              <code><%= inspect(@config_info.repo) %></code>
            </div>
          </div>
        </div>

        <.raw_config_section config_info={@config_info} />
      </div>
    </.dashboard_layout>
    """
  end
end
