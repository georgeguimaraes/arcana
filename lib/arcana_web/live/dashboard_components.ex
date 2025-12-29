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
  slot(:inner_block, required: true)

  def dashboard_layout(assigns) do
    ~H"""
    <link rel="stylesheet" href={"/arcana/css-#{ArcanaWeb.Assets.current_hash(:css)}"} />
    <div class="arcana-dashboard">
      <div class="arcana-stats">
        <div class="arcana-stat">
          <div class="arcana-stat-value"><%= @stats.documents %></div>
          <div class="arcana-stat-label">Documents</div>
        </div>
        <div class="arcana-stat">
          <div class="arcana-stat-value"><%= @stats.chunks %></div>
          <div class="arcana-stat-label">Chunks</div>
        </div>
      </div>

      <nav class="arcana-tabs">
        <.nav_link href="/arcana/documents" active={@current_tab == :documents}>Documents</.nav_link>
        <.nav_link href="/arcana/collections" active={@current_tab == :collections}>Collections</.nav_link>
        <.nav_link href="/arcana/search" active={@current_tab == :search}>Search</.nav_link>
        <.nav_link href="/arcana/ask" active={@current_tab == :ask}>Ask</.nav_link>
        <.nav_link href="/arcana/evaluation" active={@current_tab == :evaluation}>Evaluation</.nav_link>
        <.nav_link href="/arcana/maintenance" active={@current_tab == :maintenance}>Maintenance</.nav_link>
        <.nav_link href="/arcana/info" active={@current_tab == :info}>Info</.nav_link>
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

    %{documents: doc_count, chunks: chunk_count}
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
