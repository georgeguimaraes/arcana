defmodule ArcanaWeb.EvaluationLiveTest do
  use ArcanaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Arcana.Evaluation

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
      assert html =~ "Retriever"

      # Switch to history view
      view
      |> element(".arcana-eval-nav-btn", "History")
      |> render_click()

      html = render(view)
      # Should show empty history message or runs
      assert html =~ "History" || html =~ "No evaluation runs"
    end

    test "eval_switch_view falls back to test_cases on unknown view payload", %{conn: conn} do
      # Defends parse_eval_view/1 against a tampered or stale phx-value-view
      # payload. Pre-fix this used String.to_existing_atom and would crash
      # the LiveView with an ArgumentError on anything but the three known
      # views.
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      # Drive the event directly with a value that no template button emits.
      render_hook(view, "eval_switch_view", %{"view" => "garbage"})

      assert has_element?(view, ".arcana-eval-nav-btn.active", "Test Cases")
    end

    test "shows generate test cases form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      assert has_element?(view, "select[name='sample_size']")
      html = render(view)
      assert html =~ "Generate test cases"
    end
  end

  describe "Run Evaluation form" do
    test "shows retriever selector with Pipeline and Loop options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      view |> element(".arcana-eval-nav-btn", "Run Evaluation") |> render_click()

      # Both retrievers should be available as radio inputs
      assert has_element?(view, "input[type='radio'][name='retriever'][value='pipeline']")
      assert has_element?(view, "input[type='radio'][name='retriever'][value='loop']")
    end

    test "default retriever is Pipeline", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      view |> element(".arcana-eval-nav-btn", "Run Evaluation") |> render_click()

      assert has_element?(
               view,
               "input[type='radio'][name='retriever'][value='pipeline'][checked]"
             )
    end
  end

  describe "History view correctness metric" do
    test "shows Correctness metric card when run has correctness", %{conn: conn} do
      # Insert a completed run with a correctness metric.
      {:ok, run} =
        %Evaluation.Run{}
        |> Evaluation.Run.changeset(%{
          status: :completed,
          metrics: %{
            "mrr" => 0.5,
            "recall_at_5" => 0.7,
            "precision_at_5" => 0.3,
            "hit_rate_at_5" => 0.6,
            "faithfulness" => 8.1,
            "correctness" => 7.2
          },
          test_case_count: 10,
          results: %{}
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      view |> element(".arcana-eval-nav-btn", "History") |> render_click()

      html = render(view)
      assert html =~ "Correctness"
      assert html =~ "7.2"

      # Clean up so later tests don't see this run
      Evaluation.delete_run(run.id, repo: Repo)
    end

    test "does not show Correctness card when run lacks correctness metric", %{conn: conn} do
      {:ok, run} =
        %Evaluation.Run{}
        |> Evaluation.Run.changeset(%{
          status: :completed,
          metrics: %{
            "mrr" => 0.5,
            "recall_at_5" => 0.7,
            "precision_at_5" => 0.3,
            "hit_rate_at_5" => 0.6
          },
          test_case_count: 10,
          results: %{}
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, "/arcana/evaluation")

      view |> element(".arcana-eval-nav-btn", "History") |> render_click()

      html = render(view)
      refute html =~ "Correctness"

      Evaluation.delete_run(run.id, repo: Repo)
    end
  end
end
