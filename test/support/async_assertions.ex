defmodule ArcanaWeb.AsyncAssertions do
  @moduledoc """
  Waiting on LiveView work that finishes in another process.

  A submit that spawns a task returns before the task pushes its result, so
  asserting straight afterwards races it. A fixed `Process.sleep/1` before
  the assertion turns that race into "usually long enough", and a loaded CI
  runner is exactly where it stops being long enough.

  These poll for the condition instead, so they return as soon as it holds
  and only fail once it genuinely hasn't happened.
  """
  import ExUnit.Assertions

  @attempts 100
  @interval 20

  @doc """
  Renders `view` until the markup contains `expected`, then returns it.

  Fails with the last markup rendered if it never appears.
  """
  def render_until(view, expected, attempts \\ @attempts) do
    html = Phoenix.LiveViewTest.render(view)

    cond do
      html =~ expected ->
        html

      attempts <= 0 ->
        flunk("""
        timed out after #{@attempts * @interval}ms waiting for the render to contain:

            #{inspect(expected)}
        """)

      true ->
        # Process.sleep/1 returns :ok, so `sleep || recurse` would
        # short-circuit and never retry. Keep these as statements.
        Process.sleep(@interval)
        render_until(view, expected, attempts - 1)
    end
  end

  @doc """
  Polls `fun` until it returns a truthy value.

  For conditions that aren't about rendered markup, such as a row the async
  work is expected to write.
  """
  def wait_until(fun, attempts \\ @attempts) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("timed out after #{@attempts * @interval}ms waiting for the condition to hold")

      true ->
        Process.sleep(@interval)
        wait_until(fun, attempts - 1)
    end
  end
end
