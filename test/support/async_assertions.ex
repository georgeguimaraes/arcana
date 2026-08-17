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

  On a timeout the failure carries the markup that was actually rendered,
  which is the thing you need to tell "never arrived" from "arrived in a
  different shape".
  """
  def render_until(view, expected, attempts \\ @attempts) do
    poll_render(view, expected, attempts, attempts)
  end

  defp poll_render(view, expected, remaining, total) do
    html = Phoenix.LiveViewTest.render(view)

    cond do
      html =~ expected ->
        html

      remaining <= 0 ->
        flunk("""
        timed out after #{budget(total)} waiting for the render to contain:

            #{inspect(expected)}

        last rendered markup:

        #{html}
        """)

      true ->
        # Process.sleep/1 returns :ok, so `sleep || recurse` would
        # short-circuit and never retry. Keep these as statements.
        Process.sleep(@interval)
        poll_render(view, expected, remaining - 1, total)
    end
  end

  @doc """
  Polls `fun` until it returns a truthy value.

  For conditions that aren't about rendered markup, such as a row the async
  work is expected to write.
  """
  def wait_until(fun, attempts \\ @attempts) do
    poll_until(fun, attempts, attempts)
  end

  defp poll_until(fun, remaining, total) do
    cond do
      fun.() ->
        true

      remaining <= 0 ->
        flunk("timed out after #{budget(total)} waiting for the condition to hold")

      true ->
        Process.sleep(@interval)
        poll_until(fun, remaining - 1, total)
    end
  end

  # Reported from the attempts the caller actually asked for, not the
  # default: by the time we flunk, the countdown is at zero.
  defp budget(total), do: "#{total * @interval}ms"
end
