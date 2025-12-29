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
     |> load_data()}
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
      embedding: format_embedding_config(Application.get_env(:arcana, :embedding, :local)),
      reranker: format_reranker_config(Application.get_env(:arcana, :reranker))
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

      _ ->
        %{configured: true, type: inspect(llm)}
    end
  end

  defp format_embedding_config(:local), do: %{type: :local, model: "BAAI/bge-small-en-v1.5"}
  defp format_embedding_config(:openai), do: %{type: :openai, model: "text-embedding-3-small"}
  defp format_embedding_config(:zai), do: %{type: :zai, model: "embedding-3", dimensions: 1536}

  defp format_embedding_config({:local, opts}) do
    %{type: :local, model: Keyword.get(opts, :model, "BAAI/bge-small-en-v1.5")}
  end

  defp format_embedding_config({:openai, opts}) do
    %{type: :openai, model: Keyword.get(opts, :model, "text-embedding-3-small")}
  end

  defp format_embedding_config({:zai, opts}) do
    %{type: :zai, model: "embedding-3", dimensions: Keyword.get(opts, :dimensions, 1536)}
  end

  defp format_embedding_config({:custom, _fun}), do: %{type: :custom}
  defp format_embedding_config({:custom, _fun, _opts}), do: %{type: :custom}

  defp format_embedding_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{type: :custom_module, module: module, opts: opts}
  end

  defp format_embedding_config(module) when is_atom(module) do
    %{type: :custom_module, module: module}
  end

  defp format_embedding_config(other), do: %{type: :unknown, raw: inspect(other)}

  defp format_reranker_config(nil), do: %{module: Arcana.Reranker.LLM, configured: false}

  defp format_reranker_config(module) when is_atom(module),
    do: %{module: module, configured: true}

  defp format_reranker_config({module, opts}) when is_atom(module) and is_list(opts) do
    %{module: module, opts: opts, configured: true}
  end

  defp format_reranker_config(fun) when is_function(fun) do
    %{type: :function, configured: true}
  end

  defp format_reranker_config(other), do: %{type: :unknown, raw: inspect(other), configured: true}

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:info}>
      <div class="arcana-info">
        <h2>Info</h2>
        <p class="arcana-tab-description">
          View current Arcana configuration including embedding, LLM, and chunking settings.
        </p>

        <div class="arcana-info-section">
          <h3>Repository</h3>
          <div class="arcana-doc-info">
            <div class="arcana-doc-field">
              <label>Module</label>
              <code><%= inspect(@config_info.repo) %></code>
            </div>
          </div>
        </div>

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
                <span style="color: #9ca3af;">Not configured</span>
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
          <h3>Raw Configuration</h3>
          <pre class="arcana-doc-content" style="font-size: 0.75rem;">config :arcana,
    repo: <%= inspect(@config_info.repo) %>,
    embedding: <%= inspect(Application.get_env(:arcana, :embedding, :local)) %>,
    llm: <%= if Application.get_env(:arcana, :llm), do: inspect(Application.get_env(:arcana, :llm)), else: "nil" %>,
    reranker: <%= if Application.get_env(:arcana, :reranker), do: inspect(Application.get_env(:arcana, :reranker)), else: "Arcana.Reranker.LLM (default)" %></pre>
        </div>
      </div>
    </.dashboard_layout>
    """
  end
end
