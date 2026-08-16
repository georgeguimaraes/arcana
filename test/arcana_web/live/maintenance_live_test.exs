defmodule ArcanaWeb.MaintenanceLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Collection
  alias Arcana.Graph.Community

  describe "Maintenance page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Maintenance"
    end

    test "shows navigation with maintenance tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/maintenance']")
    end

    test "shows embedding configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Embedding Configuration"
      assert html =~ "Type"
    end

    test "shows re-embed section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Re-embed Chunks"
    end

    test "has re-embed button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      assert has_element?(view, "button[phx-click='reembed']")
    end
  end

  describe "community summarization" do
    setup do
      {:ok, collection} =
        Collection.get_or_create("summarize-#{System.unique_integer([:positive])}", Repo)

      %{collection: collection}
    end

    # The dashboard's maintenance actions run in a supervised task, so the
    # result lands in the LiveView asynchronously.
    defp wait_for(view, expected, attempts \\ 100) do
      html = render(view)

      cond do
        html =~ expected ->
          true

        attempts == 0 ->
          flunk("timed out waiting for #{inspect(expected)}")

        true ->
          # Process.sleep/1 returns :ok, so `sleep || recurse` short-circuits
          # and never retries. Keep these as statements.
          Process.sleep(20)
          wait_for(view, expected, attempts - 1)
      end
    end

    defp insert_community(collection, attrs) do
      %Community{}
      |> Community.changeset(Map.merge(%{level: 0, collection_id: collection.id}, attrs))
      |> Repo.insert!()
    end

    test "offers a summarize action next to detect when an LLM is configured", %{conn: conn} do
      put_arcana_env(:llm, fn _prompt, _context, _opts -> {:ok, "summary"} end)

      {:ok, view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "Summarize Communities"
      assert has_element?(view, "button[phx-click='summarize_communities']")
    end

    test "hints how many communities still need summarizing", %{
      conn: conn,
      collection: collection
    } do
      put_arcana_env(:llm, fn _prompt, _context, _opts -> {:ok, "summary"} end)
      insert_community(collection, %{entity_ids: [], summary: nil, dirty: true})
      insert_community(collection, %{entity_ids: [], summary: "done", dirty: false})

      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      assert has_element?(view, ".arcana-summarize-hint", "1 communities need summarizing")
    end

    test "summarizing writes summaries and clears the hint", %{
      conn: conn,
      collection: collection
    } do
      put_arcana_env(:llm, fn _prompt, _context, _opts -> {:ok, "a summary"} end)
      community = insert_community(collection, %{entity_ids: [], summary: nil, dirty: true})

      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      render_click(view, "summarize_communities")

      # The count matters: the flash reads "Summarized N communities", so a
      # bare "Summarized" also matches a run that summarized nothing. That
      # made a no-op run sail past this line and fail on the hint below,
      # pointing at the wrong thing.
      assert wait_for(view, "Summarized 1 communities")

      refute has_element?(view, ".arcana-summarize-hint")
      assert Repo.get!(Community, community.id).summary == "a summary"
    end

    test "detecting communities survives the stage-shaped progress callbacks", %{conn: conn} do
      # Maintenance calls progress with {:collection_start, map} too, which
      # used to reach the progress bar and crash the LiveView on render.
      {:ok, view, _html} = live(conn, "/arcana/maintenance")

      render_click(view, "detect_communities")

      assert wait_for(view, "Detected")
    end

    test "disables the action with a hint when no LLM is configured", %{conn: conn} do
      put_arcana_env(:llm, nil)

      {:ok, view, html} = live(conn, "/arcana/maintenance")

      assert html =~ "No LLM configured. Set :arcana, :llm in your config."
      assert has_element?(view, "button.arcana-summarize-btn[disabled]")
      refute has_element?(view, "button[phx-click='summarize_communities']")
    end
  end
end
