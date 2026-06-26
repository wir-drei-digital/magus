defmodule MagusWeb.Workbench.TestHelpers do
  @moduledoc """
  Shared test helpers for workbench LiveView tests. Polling helper to
  replace Process.sleep + render-check patterns that are flaky under load.
  """

  import ExUnit.Assertions

  @doc """
  Polls `fun` every `interval_ms` until it returns truthy or `timeout_ms`
  elapses. Fails the test on timeout.
  """
  @spec poll_until((-> any()), pos_integer(), pos_integer()) :: :ok
  def poll_until(fun, timeout_ms \\ 2_000, interval_ms \\ 25) do
    started = System.monotonic_time(:millisecond)

    do_poll = fn do_poll ->
      cond do
        fun.() ->
          :ok

        System.monotonic_time(:millisecond) - started > timeout_ms ->
          flunk("poll_until timed out after #{timeout_ms}ms")

        true ->
          Process.sleep(interval_ms)
          do_poll.(do_poll)
      end
    end

    do_poll.(do_poll)
  end
end
