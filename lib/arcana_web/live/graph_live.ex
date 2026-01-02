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

  alias Arcana.Graph.{Community, Entity, EntityMention, Relationship}

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
       community_level_filter: nil
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
    selected = socket.assigns.selected_collection
    name_filter = socket.assigns.entity_filter || ""
    type_filter = socket.assigns.entity_type_filter

    query =
      from(e in Entity,
        join: c in Arcana.Collection,
        on: c.id == e.collection_id,
        left_join: m in EntityMention,
        on: m.entity_id == e.id,
        left_join: r in Relationship,
        on: r.source_id == e.id or r.target_id == e.id,
        group_by: [e.id, c.name],
        order_by: [desc: count(m.id, :distinct)],
        limit: 50,
        select: %{
          id: e.id,
          name: e.name,
          type: e.type,
          collection: c.name,
          mention_count: count(m.id, :distinct),
          relationship_count: count(r.id, :distinct)
        }
      )

    query =
      if selected do
        where(query, [e, c], c.name == ^selected)
      else
        query
      end

    query =
      if name_filter != "" do
        where(query, [e], ilike(e.name, ^"%#{name_filter}%"))
      else
        query
      end

    query =
      if type_filter && type_filter != "" do
        where(query, [e], e.type == ^type_filter)
      else
        query
      end

    entities = repo.all(query)
    assign(socket, entities: entities)
  end

  defp load_relationships(socket) do
    repo = socket.assigns.repo

    query =
      from(r in Relationship,
        join: source in Entity,
        on: source.id == r.source_id,
        join: target in Entity,
        on: target.id == r.target_id,
        join: c in Arcana.Collection,
        on: c.id == source.collection_id,
        order_by: [desc: r.strength],
        limit: 50,
        select: %{
          id: r.id,
          type: r.type,
          strength: r.strength,
          description: r.description,
          source_id: source.id,
          source_name: source.name,
          source_type: source.type,
          target_id: target.id,
          target_name: target.name,
          target_type: target.type,
          collection: c.name
        }
      )

    query =
      query
      |> apply_collection_filter(socket.assigns.selected_collection)
      |> apply_relationship_search_filter(socket.assigns.relationship_filter)
      |> apply_relationship_type_filter(socket.assigns.relationship_type_filter)
      |> apply_relationship_strength_filter(socket.assigns.relationship_strength_filter)

    relationships = repo.all(query)
    assign(socket, relationships: relationships)
  end

  defp apply_collection_filter(query, nil), do: query
  defp apply_collection_filter(query, ""), do: query

  defp apply_collection_filter(query, collection) do
    where(query, [r, source, target, c], c.name == ^collection)
  end

  defp apply_relationship_search_filter(query, nil), do: query
  defp apply_relationship_search_filter(query, ""), do: query

  defp apply_relationship_search_filter(query, search) do
    pattern = "%#{search}%"

    where(
      query,
      [r, source, target, c],
      ilike(source.name, ^pattern) or ilike(target.name, ^pattern) or ilike(r.type, ^pattern)
    )
  end

  defp apply_relationship_type_filter(query, nil), do: query
  defp apply_relationship_type_filter(query, ""), do: query
  defp apply_relationship_type_filter(query, type), do: where(query, [r], r.type == ^type)

  defp apply_relationship_strength_filter(query, "strong"),
    do: where(query, [r], r.strength >= 7)

  defp apply_relationship_strength_filter(query, "medium"),
    do: where(query, [r], r.strength >= 4 and r.strength < 7)

  defp apply_relationship_strength_filter(query, "weak"), do: where(query, [r], r.strength < 4)
  defp apply_relationship_strength_filter(query, _), do: query

  defp load_communities(socket) do
    repo = socket.assigns.repo
    selected = socket.assigns.selected_collection

    query =
      from(comm in Community,
        join: coll in Arcana.Collection,
        on: coll.id == comm.collection_id,
        order_by: [asc: comm.level, desc: comm.updated_at],
        limit: 50,
        select: %{
          id: comm.id,
          level: comm.level,
          summary: comm.summary,
          entity_ids: comm.entity_ids,
          collection: coll.name,
          dirty: comm.dirty
        }
      )

    query =
      if selected do
        where(query, [comm, coll], coll.name == ^selected)
      else
        query
      end

    communities =
      repo.all(query)
      |> Enum.map(fn c ->
        Map.put(c, :entity_count, length(c.entity_ids || []))
      end)

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

  defp load_relationship_details(repo, relationship_id) do
    relationship =
      repo.one(
        from(r in Relationship,
          join: source in Entity,
          on: source.id == r.source_id,
          join: target in Entity,
          on: target.id == r.target_id,
          where: r.id == ^relationship_id,
          select: %{
            id: r.id,
            type: r.type,
            strength: r.strength,
            description: r.description,
            source_id: source.id,
            source_name: source.name,
            source_type: source.type,
            target_id: target.id,
            target_name: target.name,
            target_type: target.type
          }
        )
      )

    %{relationship: relationship}
  end

  defp load_entity_details(repo, entity_id) do
    # Load entity with relationships
    entity =
      repo.one(
        from(e in Entity,
          where: e.id == ^entity_id,
          select: %{id: e.id, name: e.name, type: e.type, description: e.description}
        )
      )

    # Load relationships where this entity is source or target
    relationships =
      repo.all(
        from(r in Relationship,
          join: source in Entity,
          on: source.id == r.source_id,
          join: target in Entity,
          on: target.id == r.target_id,
          where: r.source_id == ^entity_id or r.target_id == ^entity_id,
          select: %{
            id: r.id,
            type: r.type,
            description: r.description,
            source_id: source.id,
            source_name: source.name,
            target_id: target.id,
            target_name: target.name
          }
        )
      )

    # Load mentions with chunk context
    mentions =
      repo.all(
        from(m in EntityMention,
          join: c in Arcana.Chunk,
          on: c.id == m.chunk_id,
          where: m.entity_id == ^entity_id,
          limit: 5,
          select: %{
            id: m.id,
            context: m.context,
            chunk_id: c.id,
            chunk_text: c.text,
            document_id: c.document_id
          }
        )
      )

    %{entity: entity, relationships: relationships, mentions: mentions}
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
              <.communities_view communities={@communities} />
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
          <ul>
            <%= for rel <- @details.relationships do %>
              <li>
                <code><%= rel.type %></code>
                → <%= if rel.source_id == @details.entity.id, do: rel.target_name, else: rel.source_name %>
              </li>
            <% end %>
          </ul>
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
              <tr id={"community-#{community.id}"}>
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
