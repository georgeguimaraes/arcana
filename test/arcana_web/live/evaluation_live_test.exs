defmodule ArcanaWeb.EvaluationLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Evaluation page" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/arcana/evaluation")

      assert html =~ "Evaluation"
    end

    test "shows navigation with evaluation tab active", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      assert has_element?(view, "a.arcana-tab.active[href='/arcana/evaluation']")
    end

    test "shows evaluation sub-navigation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      assert has_element?(view, ".arcana-eval-nav")
      html = render(view)
      assert html =~ "Test Cases"
      assert html =~ "Run Evaluation"
      assert html =~ "History"
    end

    test "switches between eval views", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      # Default view is test_cases
      assert has_element?(view, ".arcana-eval-nav-btn.active", "Test Cases")

      # Switch to run view
      view
      |> element(".arcana-eval-nav-btn", "Run Evaluation")
      |> render_click()

      html = render(view)
      assert html =~ "Search Mode"

      # Switch to history view
      view
      |> element(".arcana-eval-nav-btn", "History")
      |> render_click()

      html = render(view)
      # Should show empty history message or runs
      assert html =~ "History" || html =~ "No evaluation runs"
    end

    test "shows generate test cases form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      assert has_element?(view, "select[name='sample_size']")
      html = render(view)
      assert html =~ "Generate Test Cases"
    end
  end
end
