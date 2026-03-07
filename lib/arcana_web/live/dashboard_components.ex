defmodule ArcanaWeb.DashboardComponents do
  @moduledoc """
  Shared components for the Arcana dashboard.
  """
  use Phoenix.Component

  @doc """
  Renders the dashboard layout with stats bar, navigation, and content.
  """
  attr(:stats, :map, required: true)
  attr(:current_tab, :atom, required: true)
  attr(:mode, :atom, default: :rag)
  slot(:inner_block, required: true)

  def dashboard_layout(assigns) do
    assigns = assign(assigns, :tabs, tabs_for_mode(assigns.mode))

    ~H"""
    <link rel="stylesheet" href={"/arcana/css-#{ArcanaWeb.Assets.current_hash(:css)}"} />
    <div class={"arcana-dashboard #{if @mode == :explore, do: "arcana-mode-explore"}"}>
      <div class="arcana-stats">
        <div class="arcana-brand">Arcana</div>
        <%= if @mode == :explore do %>
          <div class="arcana-stat">
            <div class="arcana-stat-value"><%= @stats[:fulltext_documents] || 0 %></div>
            <div class="arcana-stat-label">Full-text Docs</div>
          </div>
          <div class="arcana-stat">
            <div class="arcana-stat-value"><%= @stats[:collections] || 0 %></div>
            <div class="arcana-stat-label">Collections</div>
          </div>
        <% else %>
          <div class="arcana-stat">
            <div class="arcana-stat-value"><%= @stats[:documents] || 0 %></div>
            <div class="arcana-stat-label">Documents</div>
          </div>
          <div class="arcana-stat">
            <div class="arcana-stat-value"><%= @stats[:chunks] || 0 %></div>
            <div class="arcana-stat-label">Chunks</div>
          </div>
          <%= if @stats[:entities] do %>
            <div class="arcana-stat-divider"></div>
            <div class="arcana-stat">
              <div class="arcana-stat-value"><%= @stats.entities %></div>
              <div class="arcana-stat-label">Entities</div>
            </div>
            <div class="arcana-stat">
              <div class="arcana-stat-value"><%= @stats.relationships %></div>
              <div class="arcana-stat-label">Relationships</div>
            </div>
            <div class="arcana-stat">
              <div class="arcana-stat-value"><%= @stats.communities %></div>
              <div class="arcana-stat-label">Communities</div>
            </div>
          <% end %>
        <% end %>
      </div>

      <nav class="arcana-tabs">
        <a href={tab_href(:documents, :rag)} class={"arcana-mode-tab #{if @mode == :rag, do: "active"}"}>RAG</a>
        <a href={tab_href(:documents, :explore)} class={"arcana-mode-tab #{if @mode == :explore, do: "active"}"}>Recursive</a>
        <div class="arcana-tab-divider"></div>
        <%= for tab <- @tabs do %>
          <.nav_link href={tab_href(tab, @mode)} active={@current_tab == tab}><%= tab_label(tab) %></.nav_link>
        <% end %>
        <div class="arcana-tab-spacer"></div>
        <%= for tab <- [:maintenance, :info] do %>
          <.nav_link href={tab_href(tab, @mode)} active={@current_tab == tab}><%= tab_label(tab) %></.nav_link>
        <% end %>
      </nav>

      <div class="arcana-content">
        <%= render_slot(@inner_block) %>
      </div>
    </div>
    """
  end

  attr(:href, :string, required: true)
  attr(:active, :boolean, default: false)
  slot(:inner_block, required: true)

  defp nav_link(assigns) do
    ~H"""
    <a href={@href} class={"arcana-tab #{if @active, do: "active", else: ""}"}>
      <%= render_slot(@inner_block) %>
    </a>
    """
  end

  defp tabs_for_mode(:explore), do: [:documents, :collections, :explore]

  defp tabs_for_mode(_),
    do: [:documents, :collections, :graph, :search, :ask, :evaluation]

  defp tab_href(tab, :explore), do: "/arcana/#{tab}?mode=explore"
  defp tab_href(tab, _mode), do: "/arcana/#{tab}"

  defp tab_label(:documents), do: "Documents"
  defp tab_label(:collections), do: "Collections"
  defp tab_label(:graph), do: "Graph"
  defp tab_label(:search), do: "Search"
  defp tab_label(:ask), do: "Ask"
  defp tab_label(:explore), do: "Explore"
  defp tab_label(:evaluation), do: "Evaluation"
  defp tab_label(:maintenance), do: "Maintenance"
  defp tab_label(:info), do: "Info"

  # Helper functions shared across dashboard pages
  def parse_int(nil, default), do: default
  def parse_int("", default), do: default

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  def parse_float(nil, default), do: default
  def parse_float("", default), do: default

  def parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {num, _} -> num
      :error -> default
    end
  end

  def parse_mode("semantic"), do: :semantic
  def parse_mode("fulltext"), do: :fulltext
  def parse_mode("hybrid"), do: :hybrid
  def parse_mode(_), do: :semantic

  def parse_format("plaintext"), do: :plaintext
  def parse_format("markdown"), do: :markdown
  def parse_format("elixir"), do: :elixir
  def parse_format(_), do: :plaintext

  def normalize_collection(""), do: "default"
  def normalize_collection(nil), do: "default"
  def normalize_collection(name) when is_binary(name), do: name

  def blank_to_nil(""), do: nil
  def blank_to_nil(nil), do: nil
  def blank_to_nil(value), do: value

  def format_metadata(nil), do: "-"
  def format_metadata(metadata) when metadata == %{}, do: "-"

  def format_metadata(metadata) when is_map(metadata) do
    Enum.map_join(metadata, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  def format_pct(nil), do: "-"
  def format_pct(value) when is_float(value), do: "#{Float.round(value * 100, 1)}%"
  def format_pct(value) when is_integer(value), do: "#{value}%"

  def format_score(nil), do: "-"
  def format_score(value) when is_float(value), do: "#{Float.round(value, 1)}/10"
  def format_score(value) when is_integer(value), do: "#{value}/10"

  def error_to_string(:too_large), do: "File too large (max 10MB)"
  def error_to_string(:too_many_files), do: "Too many files (max 10)"
  def error_to_string(:not_accepted), do: "File type not supported"
  def error_to_string(err), do: "Error: #{inspect(err)}"

  # Shared data loading functions
  def load_stats(repo) do
    import Ecto.Query

    doc_count = repo.aggregate(Arcana.Document, :count)
    chunk_count = repo.one(from(c in Arcana.Chunk, select: count(c.id))) || 0

    base_stats = %{documents: doc_count, chunks: chunk_count}

    # Add graph stats if GraphRAG is available
    if Arcana.Graph.enabled?() do
      graph_stats = load_graph_stats(repo)
      Map.merge(base_stats, graph_stats)
    else
      base_stats
    end
  end

  def load_stats(repo, :explore) do
    import Ecto.Query

    fulltext_count =
      repo.one(
        from(d in Arcana.Document,
          where: d.chunk_count == 0 and d.status == :completed,
          select: count(d.id)
        )
      ) || 0

    collection_count = repo.aggregate(Arcana.Collection, :count)

    %{fulltext_documents: fulltext_count, collections: collection_count}
  end

  def load_stats(repo, _mode), do: load_stats(repo)

  def parse_dashboard_mode("explore"), do: :explore
  def parse_dashboard_mode(_), do: :rag

  defp load_graph_stats(repo) do
    import Ecto.Query

    entity_count = repo.one(from(e in Arcana.Graph.Entity, select: count(e.id))) || 0
    relationship_count = repo.one(from(r in Arcana.Graph.Relationship, select: count(r.id))) || 0
    community_count = repo.one(from(c in Arcana.Graph.Community, select: count(c.id))) || 0

    %{entities: entity_count, relationships: relationship_count, communities: community_count}
  rescue
    # Tables might not exist if GraphRAG not installed
    _ -> %{}
  end

  def load_collections(repo) do
    import Ecto.Query

    repo.all(
      from(c in Arcana.Collection,
        left_join: d in Arcana.Document,
        on: d.collection_id == c.id,
        group_by: c.id,
        order_by: c.name,
        select: %{
          id: c.id,
          name: c.name,
          description: c.description,
          document_count: count(d.id)
        }
      )
    )
  end

  def load_source_ids(repo) do
    import Ecto.Query

    repo.all(
      from(d in Arcana.Document,
        where: not is_nil(d.source_id),
        distinct: d.source_id,
        select: d.source_id
      )
    )
  end

  def get_repo_from_session(session) do
    session["repo"] || Application.get_env(:arcana, :repo) ||
      raise "Missing :arcana, :repo config"
  end
end
