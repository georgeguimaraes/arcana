defmodule ArcanaWeb.GraphLive do
  @moduledoc """
  LiveView for exploring the GraphRAG knowledge graph.

  Provides three sub-views:
  - Entities: Browse and search entities with their relationships and source chunks
  - Relationships: Explore entity relationships with strength indicators
  - Communities: View community clusters with LLM-generated summaries
  """
  use Phoenix.LiveView

  import ArcanaWeb.DashboardComponents
  import Ecto.Query

  alias Arcana.Graph.{Entity, GraphStore}

  @impl true
  def mount(_params, session, socket) do
    repo = get_repo_from_session(session)

    {:ok,
     socket
     |> assign(repo: repo)
     |> assign(
       current_subtab: :entities,
       selected_collection: nil,
       collections: [],
       entities: [],
       relationships: [],
       communities: [],
       stats: nil,
       entity_filter: "",
       entity_type_filter: nil,
       selected_entity: nil,
       entity_details: nil,
       relationship_filter: "",
       relationship_type_filter: nil,
       relationship_strength_filter: nil,
       selected_relationship: nil,
       relationship_details: nil,
       community_filter: "",
       community_level_filter: nil,
       selected_community: nil,
       community_details: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    subtab =
      case params["tab"] do
        "relationships" -> :relationships
        "communities" -> :communities
        _ -> :entities
      end

    selected_collection = params["collection"]

    {:noreply,
     socket
     |> assign(current_subtab: subtab, selected_collection: selected_collection)
     |> load_data()}
  end

  defp load_data(socket) do
    repo = socket.assigns.repo

    socket
    |> assign(stats: load_stats(repo))
    |> load_collections_with_graph_status()
    |> load_subtab_data()
  end

  defp load_collections_with_graph_status(socket) do
    repo = socket.assigns.repo

    collections =
      repo.all(
        from(c in Arcana.Collection,
          left_join: e in Entity,
          on: e.collection_id == c.id,
          group_by: c.id,
          order_by: c.name,
          select: %{
            id: c.id,
            name: c.name,
            description: c.description,
            entity_count: count(e.id, :distinct)
          }
        )
      )
      |> Enum.map(fn c ->
        Map.put(c, :graph_enabled, c.entity_count > 0)
      end)

    assign(socket, collections: collections)
  end

  defp load_subtab_data(%{assigns: %{current_subtab: :entities}} = socket) do
    load_entities(socket)
  end

  defp load_subtab_data(%{assigns: %{current_subtab: :relationships}} = socket) do
    load_relationships(socket)
  end

  defp load_subtab_data(%{assigns: %{current_subtab: :communities}} = socket) do
    load_communities(socket)
  end

  defp load_entities(socket) do
    repo = socket.assigns.repo
    collection_id = get_selected_collection_id(socket)
    name_filter = socket.assigns.entity_filter || ""
    type_filter = socket.assigns.entity_type_filter

    opts =
      [repo: repo, limit: 50]
      |> maybe_add_opt(:collection_id, collection_id)
      |> maybe_add_opt(:search, if(name_filter != "", do: name_filter))
      |> maybe_add_opt(:type, if(type_filter && type_filter != "", do: type_filter))

    entities = GraphStore.list_entities(opts)
    assign(socket, entities: entities)
  end

  defp load_relationships(socket) do
    repo = socket.assigns.repo
    collection_id = get_selected_collection_id(socket)
    search_filter = socket.assigns.relationship_filter
    type_filter = socket.assigns.relationship_type_filter
    strength_filter = socket.assigns.relationship_strength_filter

    opts =
      [repo: repo, limit: 50]
      |> maybe_add_opt(:collection_id, collection_id)
      |> maybe_add_opt(:search, if(search_filter && search_filter != "", do: search_filter))
      |> maybe_add_opt(:type, if(type_filter && type_filter != "", do: type_filter))
      |> maybe_add_opt(:strength, strength_filter)

    relationships = GraphStore.list_relationships(opts)
    assign(socket, relationships: relationships)
  end

  defp load_communities(socket) do
    repo = socket.assigns.repo
    collection_id = get_selected_collection_id(socket)
    search_filter = socket.assigns.community_filter
    level_filter = socket.assigns.community_level_filter

    # Parse level filter to integer if it's a string
    level =
      case level_filter do
        nil ->
          nil

        "" ->
          nil

        level when is_integer(level) ->
          level

        level when is_binary(level) ->
          case Integer.parse(level) do
            {int, _} -> int
            :error -> nil
          end
      end

    opts =
      [repo: repo, limit: 50]
      |> maybe_add_opt(:collection_id, collection_id)
      |> maybe_add_opt(:search, if(search_filter && search_filter != "", do: search_filter))
      |> maybe_add_opt(:level, level)

    communities = GraphStore.list_communities(opts)
    assign(socket, communities: communities)
  end

  @impl true
  def handle_event("switch_subtab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, tab: tab))}
  end

  def handle_event("select_collection", %{"collection" => ""}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, collection: nil))}
  end

  def handle_event("select_collection", %{"collection" => collection}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, collection: collection))}
  end

  def handle_event("filter_entities", params, socket) do
    name_filter = params["name"] || ""
    type_filter = params["type"]

    {:noreply,
     socket
     |> assign(entity_filter: name_filter, entity_type_filter: type_filter)
     |> load_entities()}
  end

  def handle_event("select_entity", %{"id" => id}, socket) do
    details = load_entity_details(socket.assigns.repo, id)
    {:noreply, assign(socket, selected_entity: id, entity_details: details)}
  end

  def handle_event("close_entity_detail", _params, socket) do
    {:noreply, assign(socket, selected_entity: nil, entity_details: nil)}
  end

  def handle_event("filter_relationships", params, socket) do
    search_filter = params["search"] || ""
    type_filter = params["type"]
    strength_filter = params["strength"]

    {:noreply,
     socket
     |> assign(
       relationship_filter: search_filter,
       relationship_type_filter: type_filter,
       relationship_strength_filter: strength_filter
     )
     |> load_relationships()}
  end

  def handle_event("select_relationship", %{"id" => id}, socket) do
    details = load_relationship_details(socket.assigns.repo, id)
    {:noreply, assign(socket, selected_relationship: id, relationship_details: details)}
  end

  def handle_event("close_relationship_detail", _params, socket) do
    {:noreply, assign(socket, selected_relationship: nil, relationship_details: nil)}
  end

  def handle_event("filter_communities", params, socket) do
    search_filter = params["search"] || ""
    level_filter = params["level"]

    {:noreply,
     socket
     |> assign(
       community_filter: search_filter,
       community_level_filter: level_filter
     )
     |> load_communities()}
  end

  def handle_event("select_community", %{"id" => id}, socket) do
    details = load_community_details(socket.assigns.repo, id)
    {:noreply, assign(socket, selected_community: id, community_details: details)}
  end

  def handle_event("close_community_detail", _params, socket) do
    {:noreply, assign(socket, selected_community: nil, community_details: nil)}
  end

  defp load_relationship_details(repo, relationship_id) do
    case GraphStore.get_relationship(relationship_id, repo: repo) do
      {:ok, relationship} -> %{relationship: relationship}
      {:error, :not_found} -> %{relationship: nil}
    end
  end

  defp load_entity_details(repo, entity_id) do
    entity =
      case GraphStore.get_entity(entity_id, repo: repo) do
        {:ok, e} -> e
        {:error, :not_found} -> nil
      end

    relationships = GraphStore.get_relationships(entity_id, repo: repo)
    mentions = GraphStore.get_mentions(entity_id, repo: repo, limit: 5)

    %{entity: entity, relationships: relationships, mentions: mentions}
  end

  defp load_community_details(repo, community_id) do
    case GraphStore.get_community(community_id, repo: repo) do
      {:ok, community} ->
        build_community_details(community, repo)

      {:error, :not_found} ->
        %{community: nil, entities: [], internal_relationships: []}
    end
  end

  defp build_community_details(community, repo) do
    entity_ids = community.entity_ids || []

    entities = load_community_entities(entity_ids, repo)
    internal_relationships = load_internal_relationships(entity_ids, repo)

    %{community: community, entities: entities, internal_relationships: internal_relationships}
  end

  defp load_community_entities(entity_ids, repo) do
    entity_ids
    |> Enum.map(&fetch_entity_summary(&1, repo))
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_entity_summary(id, repo) do
    case GraphStore.get_entity(id, repo: repo) do
      {:ok, entity} -> %{id: entity.id, name: entity.name, type: entity.type}
      {:error, :not_found} -> nil
    end
  end

  defp load_internal_relationships(entity_ids, _repo) when length(entity_ids) < 2, do: []

  defp load_internal_relationships(entity_ids, repo) do
    entity_ids
    |> Enum.flat_map(fn id -> GraphStore.get_relationships(id, repo: repo) end)
    |> Enum.filter(fn rel -> rel.source_id in entity_ids and rel.target_id in entity_ids end)
    |> Enum.uniq_by(& &1.id)
  end

  defp build_path(socket, overrides) do
    tab = Keyword.get(overrides, :tab, Atom.to_string(socket.assigns.current_subtab))

    collection =
      case Keyword.fetch(overrides, :collection) do
        {:ok, nil} -> nil
        {:ok, c} -> c
        :error -> socket.assigns.selected_collection
      end

    params =
      [tab: tab, collection: collection]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    "/arcana/graph?" <> URI.encode_query(params)
  end

  defp has_any_graph_data?(collections) do
    Enum.any?(collections, & &1.graph_enabled)
  end

  defp get_selected_collection_id(socket) do
    selected_name = socket.assigns.selected_collection

    if selected_name do
      socket.assigns.collections
      |> Enum.find(fn c -> c.name == selected_name end)
      |> case do
        nil -> nil
        collection -> collection.id
      end
    else
      nil
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  @impl true
  def render(assigns) do
    ~H"""
    <.dashboard_layout stats={@stats} current_tab={:graph}>
      <div class="arcana-graph">
        <h2>Graph</h2>
        <p class="arcana-tab-description">
          Explore entities, relationships, and communities extracted from your documents.
        </p>

        <div class="arcana-collection-selector">
          <label>Collection:</label>
          <select phx-change="select_collection" name="collection">
            <option value="">All Collections</option>
            <%= for coll <- @collections do %>
              <option value={coll.name} selected={@selected_collection == coll.name}>
                <%= coll.name %>
                <%= if coll.graph_enabled, do: "✓", else: "✗" %>
              </option>
            <% end %>
          </select>
        </div>

        <%= if not has_any_graph_data?(@collections) do %>
          <div class="arcana-empty-state">
            <h3>No Graph Data Yet</h3>
            <p>Enable GraphRAG during document ingestion:</p>
            <pre><code>Arcana.ingest(text, repo: Repo, graph: true)</code></pre>
            <p>This extracts entities and relationships to enhance search.</p>
          </div>
        <% else %>
          <div class="arcana-graph-subtabs">
            <button
              class={"arcana-subtab-btn #{if @current_subtab == :entities, do: "active", else: ""}"}
              phx-click="switch_subtab"
              phx-value-tab="entities"
            >
              Entities
            </button>
            <button
              class={"arcana-subtab-btn #{if @current_subtab == :relationships, do: "active", else: ""}"}
              phx-click="switch_subtab"
              phx-value-tab="relationships"
            >
              Relationships
            </button>
            <button
              class={"arcana-subtab-btn #{if @current_subtab == :communities, do: "active", else: ""}"}
              phx-click="switch_subtab"
              phx-value-tab="communities"
            >
              Communities
            </button>
          </div>

          <%= case @current_subtab do %>
            <% :entities -> %>
              <.entities_view
                entities={@entities}
                entity_filter={@entity_filter}
                entity_type_filter={@entity_type_filter}
                selected_entity={@selected_entity}
                entity_details={@entity_details}
              />
            <% :relationships -> %>
              <.relationships_view
                relationships={@relationships}
                relationship_filter={@relationship_filter}
                relationship_type_filter={@relationship_type_filter}
                relationship_strength_filter={@relationship_strength_filter}
                selected_relationship={@selected_relationship}
                relationship_details={@relationship_details}
              />
            <% :communities -> %>
              <.communities_view
                communities={@communities}
                community_filter={@community_filter}
                community_level_filter={@community_level_filter}
                selected_community={@selected_community}
                community_details={@community_details}
              />
          <% end %>
        <% end %>
      </div>
    </.dashboard_layout>
    """
  end

  defp entities_view(assigns) do
    ~H"""
    <div class="arcana-entities-view">
      <form phx-change="filter_entities" class="arcana-filter-bar">
        <input
          type="text"
          name="name"
          value={@entity_filter}
          placeholder="Search entities..."
          class="arcana-input"
          phx-debounce="300"
        />
        <select name="type" class="arcana-input">
          <option value="">All Types</option>
          <option value="person" selected={@entity_type_filter == "person"}>Person</option>
          <option value="organization" selected={@entity_type_filter == "organization"}>
            Organization
          </option>
          <option value="technology" selected={@entity_type_filter == "technology"}>Technology</option>
          <option value="concept" selected={@entity_type_filter == "concept"}>Concept</option>
          <option value="location" selected={@entity_type_filter == "location"}>Location</option>
          <option value="event" selected={@entity_type_filter == "event"}>Event</option>
        </select>
      </form>

      <%= if Enum.empty?(@entities) do %>
        <div class="arcana-empty">No entities found matching your criteria.</div>
      <% else %>
        <table class="arcana-table arcana-graph-table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Type</th>
              <th>Mentions</th>
              <th>Relationships</th>
            </tr>
          </thead>
          <tbody>
            <%= for entity <- @entities do %>
              <tr
                id={"entity-#{entity.id}"}
                class={"arcana-entity-row #{if @selected_entity == entity.id, do: "selected", else: ""}"}
                phx-click="select_entity"
                phx-value-id={entity.id}
              >
                <td><%= entity.name %></td>
                <td>
                  <span class={"arcana-entity-type-badge #{entity.type}"}>
                    <%= entity.type %>
                  </span>
                </td>
                <td><%= entity.mention_count %></td>
                <td><%= entity.relationship_count %></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>

      <%= if @entity_details do %>
        <.entity_detail_panel details={@entity_details} />
      <% end %>
    </div>
    """
  end

  defp entity_detail_panel(assigns) do
    ~H"""
    <div class="arcana-entity-detail">
      <div class="arcana-entity-detail-header">
        <h3><%= @details.entity.name %></h3>
        <span class={"arcana-entity-type-badge #{@details.entity.type}"}>
          <%= @details.entity.type %>
        </span>
        <button class="arcana-entity-detail-close" phx-click="close_entity_detail">×</button>
      </div>

      <%= if @details.entity.description do %>
        <p class="arcana-entity-description"><%= @details.entity.description %></p>
      <% end %>

      <%= if Enum.any?(@details.relationships) do %>
        <div class="arcana-entity-relationships">
          <h4>Relationships</h4>
          <div class="arcana-rel-cards">
            <%= for rel <- @details.relationships do %>
              <div class="arcana-rel-card">
                <%= if rel.source_id == @details.entity.id do %>
                  <span class="arcana-rel-type"><%= rel.type %></span>
                  <span class="arcana-rel-arrow">→</span>
                  <span class="arcana-rel-target"><%= rel.target_name %></span>
                <% else %>
                  <span class="arcana-rel-source"><%= rel.source_name %></span>
                  <span class="arcana-rel-arrow">→</span>
                  <span class="arcana-rel-type"><%= rel.type %></span>
                  <span class="arcana-rel-arrow">→</span>
                  <span class="arcana-rel-self">(this)</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <%= if Enum.any?(@details.mentions) do %>
        <div class="arcana-entity-mentions">
          <h4>Source Chunks</h4>
          <%= for mention <- @details.mentions do %>
            <div class="arcana-mention-preview">
              <p><%= String.slice(mention.context || mention.chunk_text || "", 0, 200) %></p>
              <a
                href={"/arcana/documents?doc=#{mention.document_id}"}
                class="arcana-view-in-docs"
              >
                View in Documents →
              </a>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp relationships_view(assigns) do
    ~H"""
    <div class="arcana-relationships-view">
      <form phx-change="filter_relationships" class="arcana-filter-bar">
        <input
          type="text"
          name="search"
          value={@relationship_filter}
          placeholder="Search relationships..."
          class="arcana-input"
          phx-debounce="300"
        />
        <select name="type" class="arcana-input">
          <option value="">All Types</option>
          <option value="LEADS" selected={@relationship_type_filter == "LEADS"}>LEADS</option>
          <option value="CREATED" selected={@relationship_type_filter == "CREATED"}>CREATED</option>
          <option value="PARTNERED" selected={@relationship_type_filter == "PARTNERED"}>
            PARTNERED
          </option>
          <option value="ENABLES" selected={@relationship_type_filter == "ENABLES"}>ENABLES</option>
          <option value="WORKS_AT" selected={@relationship_type_filter == "WORKS_AT"}>WORKS_AT</option>
          <option value="RELATED_TO" selected={@relationship_type_filter == "RELATED_TO"}>
            RELATED_TO
          </option>
        </select>
        <select name="strength" class="arcana-input">
          <option value="">Any Strength</option>
          <option value="strong" selected={@relationship_strength_filter == "strong"}>
            Strong (7-10)
          </option>
          <option value="medium" selected={@relationship_strength_filter == "medium"}>
            Medium (4-6)
          </option>
          <option value="weak" selected={@relationship_strength_filter == "weak"}>Weak (1-3)</option>
        </select>
      </form>

      <%= if Enum.empty?(@relationships) do %>
        <div class="arcana-empty">No relationships found matching your criteria.</div>
      <% else %>
        <table class="arcana-table arcana-graph-table">
          <thead>
            <tr>
              <th>Source</th>
              <th>Relationship</th>
              <th>Target</th>
              <th>Strength</th>
            </tr>
          </thead>
          <tbody>
            <%= for rel <- @relationships do %>
              <tr
                id={"relationship-#{rel.id}"}
                class={"arcana-relationship-row #{if @selected_relationship == rel.id, do: "selected", else: ""}"}
                phx-click="select_relationship"
                phx-value-id={rel.id}
              >
                <td><%= rel.source_name %></td>
                <td><code><%= rel.type %></code></td>
                <td><%= rel.target_name %></td>
                <td><.strength_meter value={rel.strength || 5} /></td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>

      <%= if @relationship_details do %>
        <.relationship_detail_panel details={@relationship_details} />
      <% end %>
    </div>
    """
  end

  defp relationship_detail_panel(assigns) do
    ~H"""
    <div class="arcana-relationship-detail">
      <div class="arcana-relationship-detail-header">
        <div class="arcana-relationship-visual">
          <span class="arcana-relationship-source"><%= @details.relationship.source_name %></span>
          <span class="arcana-relationship-arrow">→</span>
          <code class="arcana-relationship-type"><%= @details.relationship.type %></code>
          <span class="arcana-relationship-arrow">→</span>
          <span class="arcana-relationship-target"><%= @details.relationship.target_name %></span>
        </div>
        <button class="arcana-relationship-detail-close" phx-click="close_relationship_detail">
          ×
        </button>
      </div>

      <div class="arcana-relationship-strength">
        <strong>Strength:</strong> <%= @details.relationship.strength || 5 %>/10
      </div>

      <%= if @details.relationship.description do %>
        <p class="arcana-relationship-description"><%= @details.relationship.description %></p>
      <% end %>
    </div>
    """
  end

  defp communities_view(assigns) do
    ~H"""
    <div class="arcana-communities-view">
      <form phx-change="filter_communities" class="arcana-filter-bar">
        <input
          type="text"
          name="search"
          value={@community_filter}
          placeholder="Search communities..."
          class="arcana-input"
          phx-debounce="300"
        />
        <select name="level" class="arcana-input">
          <option value="">All Levels</option>
          <option value="0" selected={@community_level_filter == "0"}>Level 0</option>
          <option value="1" selected={@community_level_filter == "1"}>Level 1</option>
          <option value="2" selected={@community_level_filter == "2"}>Level 2</option>
        </select>
      </form>

      <%= if Enum.empty?(@communities) do %>
        <div class="arcana-empty">
          <p>No Communities Detected</p>
          <p class="arcana-empty-hint">
            Communities are generated when there are enough entities
            and relationships to form meaningful clusters.
          </p>
        </div>
      <% else %>
        <table class="arcana-table arcana-graph-table">
          <thead>
            <tr>
              <th>Community</th>
              <th>Level</th>
              <th>Entities</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for community <- @communities do %>
              <tr
                id={"community-#{community.id}"}
                class={"arcana-community-row #{if @selected_community == community.id, do: "selected", else: ""}"}
                phx-click="select_community"
                phx-value-id={community.id}
              >
                <td>
                  <%= if community.summary do %>
                    <%= String.slice(community.summary, 0, 50) %><%= if String.length(community.summary || "") > 50, do: "...", else: "" %>
                  <% else %>
                    <span class="arcana-no-summary">No summary</span>
                  <% end %>
                </td>
                <td><%= community.level %></td>
                <td><%= community.entity_count %></td>
                <td>
                  <%= cond do %>
                    <% community.dirty -> %>
                      <span class="arcana-status-pending" title="Pending regeneration">⟳</span>
                    <% community.summary -> %>
                      <span class="arcana-status-ready" title="Summary ready">✓</span>
                    <% true -> %>
                      <span class="arcana-status-empty" title="No summary">○</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>

      <%= if @community_details do %>
        <.community_detail_panel details={@community_details} />
      <% end %>
    </div>
    """
  end

  defp community_detail_panel(assigns) do
    ~H"""
    <div class="arcana-community-detail">
      <div class="arcana-community-detail-header">
        <h3>Community</h3>
        <span class="arcana-community-level-badge">Level <%= @details.community.level %></span>
        <button class="arcana-community-detail-close" phx-click="close_community_detail">×</button>
      </div>

      <%= if @details.community.summary do %>
        <div class="arcana-community-summary">
          <h4>Summary</h4>
          <p><%= @details.community.summary %></p>
        </div>
      <% else %>
        <div class="arcana-community-no-summary">
          <p>No summary generated yet.</p>
        </div>
      <% end %>

      <%= if Enum.any?(@details.entities) do %>
        <div class="arcana-community-entities">
          <h4>Member Entities</h4>
          <ul>
            <%= for entity <- @details.entities do %>
              <li>
                <span class={"arcana-entity-type-badge #{entity.type}"}><%= entity.type %></span>
                <%= entity.name %>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= if Enum.any?(@details.internal_relationships) do %>
        <div class="arcana-community-relationships">
          <h4>Internal Relationships</h4>
          <ul>
            <%= for rel <- @details.internal_relationships do %>
              <li>
                <%= rel.source_name %> <code><%= rel.type %></code> <%= rel.target_name %>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>
    </div>
    """
  end

  defp strength_meter(assigns) do
    value = assigns.value || 5
    filled = min(max(round(value), 0), 10)

    assigns = assign(assigns, filled: filled)

    ~H"""
    <span class="arcana-strength-meter" title={"Strength: #{@value}/10"}>
      <%= for i <- 1..10 do %>
        <span class={"arcana-strength-dot #{if i <= @filled, do: "filled", else: ""}"}></span>
      <% end %>
    </span>
    """
  end
end
